/// Mutate source code within a directory tree.
/// Recreates the directory tree in a new location, after modifying each `*.zig` file.
/// This operation is not atomic.
pub fn mutateTree(
    opts: MutateTreeOptions,
    handlers: anytype,
) !void {
    var source = std.ArrayList(u8).init(opts.allocator);
    defer source.deinit();

    var walker = try opts.source_dir.walk(opts.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                try opts.dest_dir.makeDir(entry.path);
            },

            .file => if (std.ascii.endsWithIgnoreCase(entry.basename, ".zig")) {
                // Read source code
                {
                    const f = try entry.dir.openFile(entry.basename, .{});
                    defer f.close();

                    const size = if (f.stat()) |st| st.size else |_| 0;
                    if (size > opts.max_source_file_size) {
                        return error.StreamTooLong;
                    }

                    source.clearRetainingCapacity();
                    const size_usize: usize = @intCast(size); // For 32-bit systems
                    try source.ensureTotalCapacity(size_usize + 1); // + 1 for terminator
                    try f.reader().readAllArrayList(&source, opts.max_source_file_size);
                }

                // Terminate source
                try source.append(0);
                const source_slice = source.items[0 .. source.items.len - 1 :0];

                // Mutate code
                const output = try mutate(opts.allocator, source_slice, handlers);
                defer opts.allocator.free(output);

                // Write mutated code
                try opts.dest_dir.writeFile2(.{
                    .sub_path = entry.path,
                    .data = output,
                });
            } else {
                // Not a Zig file; just copy it
                try entry.dir.copyFile(
                    entry.basename,
                    opts.dest_dir,
                    entry.path,
                    .{},
                );
            },

            // TODO: symlinks

            else => switch (opts.unhandled_file_behavior) {
                .skip => {},
                .err => return error.InvalidFileKind, // block device, unix socket, etc
            },
        }
    }
}

pub const MutateTreeOptions = struct {
    /// Allocator used during the operation.
    /// All allocations will be freed before the function returns.
    allocator: std.mem.Allocator,

    /// The source directory. Must be opened with `.iterate = true`.
    source_dir: std.fs.Dir,
    /// The destination directory.
    dest_dir: std.fs.Dir,

    /// The maximum file size for Zig source files within the source directory. Default 8MiB.
    max_source_file_size: u32 = 8 * 1024 * 1024,

    /// How to handle unusual kinds of files (block devices, unix sockets, etc.)
    /// Currently, symbolic links are included in this, but it would be good to support those.
    unhandled_file_behavior: enum { skip, err } = .err,
};

test mutateTree {
    var dest_dir = std.testing.tmpDir(.{ .iterate = true });
    defer dest_dir.cleanup();

    var test_dir = try std.fs.cwd().openDir("test-tree", .{});
    defer test_dir.close();

    {
        var source_dir = try test_dir.openDir("src", .{ .iterate = true });
        defer source_dir.close();

        try mutateTree(.{
            .allocator = std.testing.allocator,
            .source_dir = source_dir,
            .dest_dir = dest_dir.dir,
        }, struct {
            pub fn function(ctx: MutationContext(.function)) !void {
                try ctx.inject("@import(\"std\").debug.print(\"hi!\", .{{}});", .{});
            }
        });
    }

    var expected_dir = try test_dir.openDir("expected", .{ .iterate = true });
    defer expected_dir.close();

    try expectEqualTrees(expected_dir, dest_dir.dir);
}

fn expectEqualTrees(expected_dir: std.fs.Dir, actual_dir: std.fs.Dir) !void {
    { // Check everything in expected_dir is in actual_dir, and has same content
        var it = try expected_dir.walk(std.testing.allocator);
        defer it.deinit();
        while (try it.next()) |entry| {
            const stat = actual_dir.statFile(entry.path) catch {
                std.debug.print("Expected file '{'}' but it does not exist in actual directory\n", .{
                    std.zig.fmtEscapes(entry.path),
                });
                return error.TestExpectedEqual;
            };
            if (entry.kind != stat.kind) {
                std.debug.print("'{'}' is of incorrect type. Expected {s}, found {s}\n", .{
                    std.zig.fmtEscapes(entry.path),
                    @tagName(entry.kind),
                    @tagName(stat.kind),
                });
                return error.TestExpectedEqual;
            }

            switch (entry.kind) {
                .directory => {},
                .file => {
                    const expected_file = try entry.dir.openFile(entry.basename, .{});
                    defer expected_file.close();
                    const actual_file = try actual_dir.openFile(entry.path, .{});
                    defer actual_file.close();

                    // Compare file content
                    var expected_buf: [1024]u8 = undefined;
                    var actual_buf: [1024]u8 = undefined;
                    while (true) {
                        const expected_len = try expected_file.read(&expected_buf);
                        const actual_len = try actual_file.read(&actual_buf);
                        try std.testing.expectEqualStrings(
                            expected_buf[0..expected_len],
                            actual_buf[0..actual_len],
                        );

                        if (expected_len == 0 or actual_len == 0) {
                            break;
                        }
                    }
                },
                else => return error.UnexpectedFileType,
            }
        }
    }

    { // Check everything in actual_dir is in expected_dir
        var it = try actual_dir.walk(std.testing.allocator);
        defer it.deinit();
        while (try it.next()) |entry| {
            const stat = expected_dir.statFile(entry.path) catch {
                std.debug.print("Unexpected extra file '{'}'\n", .{
                    std.zig.fmtEscapes(entry.path),
                });
                return error.TestExpectedEqual;
            };
            try std.testing.expectEqual(entry.kind, stat.kind);
        }
    }
}

pub const Event = union(enum) {
    function: Function, // Emitted at the start of every function

    pub const Function = struct {
        name: []const u8,
        // TODO: provide more info
    };
};

/// Mutate the source code with the given handlers.
/// Returns modified source code, owned by the caller.
///
/// `handlers` is a type with functions, or value with methods, for each `Event`.
/// If an event is missing, it will be ignored.
///
/// Event handlers must follow the signature:
/// ```
/// pub fn event_name(self, ctx: MutationContext(.event_name)) !void
/// ```
pub fn mutate(allocator: std.mem.Allocator, source: [:0]const u8, handlers: anytype) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    {
        var ast = try Ast.parse(allocator, source, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len > 0) {
            return error.ParseError; // Error in input code
        }

        var mutator: Mutator = .{
            .allocator = allocator,
            .ast = ast,
        };
        defer {
            mutator.injections.deinit(allocator);
            mutator.injection_buf.deinit(allocator);
        }

        // Process AST nodes
        // TODO: traverse the ast in order to provide context from parents
        for (0..ast.nodes.len) |node_idx| {
            try mutateNode(&mutator, handlers, @intCast(node_idx));
        }

        // Fast path if no modifications
        if (mutator.injections.count() == 0) {
            return allocator.dupe(u8, source);
        }

        // Modify source code
        try out.ensureTotalCapacityPrecise(
            // Input + total injection buffer size - 1 for each terminator + 1 for the final terminator
            source.len + mutator.injection_buf.items.len - mutator.injections.count() + 1,
        );
        var off: u32 = 0;
        for (mutator.injections.keys(), mutator.injections.values()) |target, text_start| {
            out.appendSliceAssumeCapacity(source[off..target]);
            off = target;

            const text = std.mem.sliceTo(mutator.injection_buf.items[text_start..], 0);
            out.appendSliceAssumeCapacity(text);
        }
        out.appendSliceAssumeCapacity(source[off..]);
    }

    // Terminate output buffer
    out.appendAssumeCapacity(0);
    std.debug.assert(out.items.len == out.capacity);
    const new_src = out.items[0 .. out.items.len - 1 :0];

    // Format the modified source code
    var new_ast = try Ast.parse(allocator, new_src, .zig);
    defer new_ast.deinit(allocator);
    if (new_ast.errors.len > 0) {
        std.log.err("Error in code:\n{s}", .{new_src});
        return error.InvalidInjectedCode; // Error in injected code
    }
    return new_ast.render(allocator);
}

const Mutator = struct {
    allocator: std.mem.Allocator,
    ast: Ast,
    injections: std.AutoArrayHashMapUnmanaged(Ast.ByteOffset, u32) = .{},
    injection_buf: std.ArrayListUnmanaged(u8) = .{},
};

fn mutateNode(
    m: *Mutator,
    handlers: anytype,
    node_idx: Ast.Node.Index,
) !void {
    const node = m.ast.nodes.get(node_idx);
    switch (node.tag) {
        .fn_decl => if (handlerExists(handlers, "function")) {
            const name_tok = switch (m.ast.nodes.items(.tag)[node.data.lhs]) {
                .fn_proto_simple,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto,
                => m.ast.nodes.items(.main_token)[node.data.lhs] + 1,
                else => unreachable,
            };

            const ctx: MutationContext(.function) = .{
                .m = m,
                .event = .{
                    .name = m.ast.tokenSlice(name_tok),
                },
            };
            const inj_start = m.injection_buf.items.len;
            try @field(handlers, "function")(ctx);

            const block = m.ast.nodes.get(node.data.rhs);
            if (m.injection_buf.items.len > inj_start) {
                try m.injection_buf.append(m.allocator, 0); // Terminate string

                const offset = m.ast.tokens.items(.start)[block.main_token] + 1;
                try m.injections.putNoClobber(m.allocator, offset, @intCast(inj_start));
            }
        },

        else => {},
    }
}

inline fn handlerExists(handlers: anytype, comptime name: []const u8) bool {
    comptime {
        return if (@TypeOf(handlers) == type)
            @hasDecl(handlers, name)
        else
            @hasDecl(@TypeOf(handlers), name);
    }
}

// Event context provided to `mutate` event handlers.
pub fn MutationContext(comptime event: std.meta.Tag(Event)) type {
    const StatementContext = struct {
        event: std.meta.fieldInfo(Event, event).type,
        m: *Mutator, // For internal use only

        const Self = @This();

        /// Inject a statement at the event location.
        pub fn inject(ctx: Self, comptime format: []const u8, args: anytype) !void {
            var buf = ctx.m.injection_buf.toManaged(ctx.m.allocator);
            defer ctx.m.injection_buf = buf.moveToUnmanaged();
            try buf.writer().print(format, args);
        }
    };

    return switch (event) {
        .function => StatementContext,
    };
}

test mutate {
    const src =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    say.hi("world");
        \\}
        \\
        \\const say = struct {
        \\    fn hi(to: []const u8) void {
        \\        std.debug.print("Hello, {}!\n", .{to});
        \\    }
        \\};
        \\
    ;

    { // Do nothing
        const out = try mutate(std.testing.allocator, src, .{});
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(src, out);
    }

    { // Inject at start of functions
        const out = try mutate(std.testing.allocator, src, struct {
            pub fn function(ctx: MutationContext(.function)) !void {
                try ctx.inject(
                    \\@import("std").log.debug("Hello from {}", .{{}});
                , .{std.zig.fmtEscapes(ctx.event.name)});
            }
        });
        defer std.testing.allocator.free(out);
        const exp =
            \\const std = @import("std");
            \\
            \\pub fn main() !void {
            \\    @import("std").log.debug("Hello from main", .{});
            \\    say.hi("world");
            \\}
            \\
            \\const say = struct {
            \\    fn hi(to: []const u8) void {
            \\        @import("std").log.debug("Hello from hi", .{});
            \\        std.debug.print("Hello, {}!\n", .{to});
            \\    }
            \\};
            \\
        ;
        try std.testing.expectEqualStrings(exp, out);
    }
}

const std = @import("std");
const Ast = std.zig.Ast;
