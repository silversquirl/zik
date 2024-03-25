//! Simple ZIK-based tracing profiler outputting to the callgrind format

pub const main = zik.wrapper.main(.{
    .zikprof = thisFile(),
}, struct {
    pub fn function(ctx: zik.MutationContext(.function)) !void {
        try ctx.inject(
            \\const {[variable]s} = @import("{[module]s}").begin(@src());
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

pub fn begin(src: std.builtin.SourceLocation) Context {
    std.debug.print("enter {s} ({s}:{d},{d})\n", .{ src.fn_name, src.file, src.line, src.column });
    return .{};
}

pub const Context = struct {
    pub fn end(ctx: Context) void {
        _ = ctx;
        std.debug.print("exit\n", .{});
    }
};

const std = @import("std");
const zik = @import("zik");
