const std = @import("std");
const Ast = std.zig.Ast;

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
/// `handlers` is a struct with methods for each `Event`.
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
