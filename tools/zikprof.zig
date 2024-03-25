//! Simple ZIK-based tracing profiler, outputting to the callgrind format.

pub const main = zik.wrapper.main(.{
    .zikprof = thisFile(),
}, struct {
    pub fn function(ctx: zik.MutationContext(.function)) !void {
        try ctx.inject(
            \\var {[variable]s}: @import("{[module]s}").Span = undefined;
            \\{[variable]s}.begin(@src());
            \\defer {[variable]s}.end();
        ,
            .{
                .module = zik.namespace ++ ".zikprof",
                .variable = "@\"" ++ zik.namespace ++ ".zikprof.span\"",
            },
        );
    }
});

fn thisFile() []const u8 {
    return @embedFile(std.fs.path.basename(@src().file));
}

const SampleEvents = struct {
    nanoseconds: u64,
};

var global: GlobalState = undefined;
var global_inited = std.atomic.Value(bool).init(false);
var global_lock: std.Thread.Mutex = .{};

var thread_count = std.atomic.Value(u32).init(0);
threadlocal var thread: ?ThreadState = null;

const GlobalState = struct {
    file: std.fs.File,
    bufw: std.io.BufferedWriter(4096, std.fs.File.Writer),

    fn init() !GlobalState {
        const pid = if (@import("builtin").os.tag == .windows)
            std.os.windows.kernel32.GetCurrentProcessId()
        else
            std.posix.system.getpid();

        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "callgrind.out.zikprof.{}", .{pid});

        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();
        var bufw = std.io.bufferedWriter(file.writer());

        const w = bufw.writer();
        try w.writeAll("# callgrind format\nevents:");
        inline for (@typeInfo(SampleEvents).Struct.fields) |field| {
            var field_name_cap = field.name[0..].*;
            field_name_cap[0] = std.ascii.toUpper(field.name[0]);
            try w.writeAll(" " ++ field_name_cap);
        }
        try w.writeAll("\n");

        return .{
            .file = file,
            .bufw = bufw,
        };
    }
    fn deinit(state: *GlobalState) void {
        std.debug.assert(global_lock.tryLock());
        defer global_lock.unlock();

        state.bufw.flush() catch @panic("zikprof: error writing buffered data");
        state.file.close();

        state.* = undefined;
        global_inited.store(false, .release);
    }

    fn enterThread(_: *GlobalState) void {
        _ = thread_count.fetchAdd(1, .acquire);
    }
    fn exitThread(state: *GlobalState) void {
        if (thread_count.fetchSub(1, .release) == 1) {
            // Last thread has exited, clean up.
            state.deinit();
        }
    }
};

const ThreadState = struct {
    valid: bool = true,
    top: ?*Span = null,
    // TODO: perf events
    timer: std.time.Timer,

    /// The most recently written source location in this thread's part
    current_loc: ?SourceLocation = null,

    fn init() !ThreadState {
        global.enterThread();
        return .{ .timer = try std.time.Timer.start() };
    }
    fn deinit(state: *ThreadState) void {
        std.debug.assert(state.valid);
        state.valid = false;
        global.exitThread();
    }

    /// Write a source location, if required.
    /// Must be called while global_lock is held.
    fn writeLocation(state: *ThreadState, loc: SourceLocation) !void {
        var file_same = false;
        var fn_same = false;
        if (state.current_loc) |cur| {
            file_same = std.mem.eql(u8, cur.file, loc.file);
            fn_same = std.mem.eql(u8, cur.fn_name, loc.fn_name);
        }
        if (file_same and fn_same) {
            // Location has not changed, do nothing
            return;
        }

        // Output info for the new location
        // TODO: properly support multithreading, using parts
        const w = global.bufw.writer();

        if (!file_same) {
            try w.print("fl={s}\n", .{loc.file});
        }
        if (!fn_same) {
            try w.print("fn={s}\n", .{loc.fn_name});
        }

        state.current_loc = loc;
    }

    /// Write a function call.
    /// Must immediately be followed by a call to `writeSample`.
    fn writeCall(state: *ThreadState, from: SourceLocation, to: SourceLocation) !void {
        // TODO: properly support multithreading, using parts

        global_lock.lock();
        defer global_lock.unlock();
        const w = global.bufw.writer();

        try state.writeLocation(from);

        if (!std.mem.eql(u8, from.file, to.file)) {
            try w.print("cfi={s}\n", .{to.file});
        }
        try w.print("cfn={s}\ncalls=1 {}\n", .{ to.fn_name, to.line });
    }

    /// Write a time sample.
    fn writeSample(state: *ThreadState, loc: SourceLocation, events: SampleEvents) !void {
        // TODO: properly support multithreading, using parts

        global_lock.lock();
        defer global_lock.unlock();
        const w = global.bufw.writer();

        try state.writeLocation(loc);

        // TODO: this is somewhat meaningless as it's always the start of the function. Maybe just use 0?
        try w.print("{}", .{loc.line});

        var prev: usize = 0;
        inline for (@typeInfo(SampleEvents).Struct.fields, 0..) |field, i| {
            const event = @field(events, field.name);
            if (event != 0) {
                try w.writeBytesNTimes(" 0", i - prev);
                prev = i + 1;
                try w.print(" {}", .{event});
            }
        }
        try w.writeAll("\n");
    }
};

fn ensureInitialized() void {
    // Global state will always be inited if thread state is, so  check thread state first
    if (thread == null) {
        if (!global_inited.load(.acquire)) {
            global_lock.lock();
            defer global_lock.unlock();
            // Can read (but not write) `raw` directly inside critical section
            if (!global_inited.raw) {
                global = GlobalState.init() catch @panic("zikprof: global init failed");
                global_inited.store(true, .release);
            }
        }

        thread = ThreadState.init() catch @panic("zikprof: thread init failed");
    }
}

pub const Span = struct {
    next: ?*Span,
    loc: SourceLocation,
    last_time: u64,

    pub fn begin(span: *Span, loc: SourceLocation) void {
        ensureInitialized();

        span.* = .{
            .loc = loc,
            .next = thread.?.top,
            .last_time = thread.?.timer.read(),
        };
        if (thread.?.top) |top| {
            top.writeSample();
        }
        thread.?.top = span;
    }

    fn writeSample(span: *Span) void {
        thread.?.writeSample(span.loc, .{
            .nanoseconds = thread.?.timer.read() - span.last_time,
        }) catch @panic("zikprof: error writing sample");
    }

    pub fn end(span: *Span) void {
        span.writeSample();
        thread.?.top = span.next;
        if (thread.?.top) |top| {
            thread.?.writeCall(top.loc, span.loc) catch @panic("zikprof: error writing call info");
            top.writeSample();
        } else {
            // Top of call stack; assuming no shenanigans, we won't be using this ThreadState again
            thread.?.deinit();
        }
    }

    fn print(span: Span, dir: u8) void {
        std.debug.print("{c} {s} ({s}:{},{}) at {}\n", .{
            dir,
            span.loc.fn_name,
            span.loc.file,
            span.loc.line,
            span.loc.column,
            thread.?.timer.read(),
        });
    }
};

const std = @import("std");
const zik = @import("zik");
const SourceLocation = std.builtin.SourceLocation;
