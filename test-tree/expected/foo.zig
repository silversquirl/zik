pub fn foo() u32 {
    @import("std").debug.print("hi!", .{});
    // This is a function! yay!
    const x = loadData();
    return bar.bar(x);
}

fn loadData() u32 {
    @import("std").debug.print("hi!", .{});
    const data = comptime std.mem.trim(u8, @embedFile("data.txt"), " \t\n");
    const num = comptime std.fmt.parseInt(u32, data, 10) catch {
        @compileError("Invalid number: " ++ data);
    };
    return num;
}

test foo {
    try std.testing.expectEqual(42076, foo());
}

const std = @import("std");
const bar = @import("subdir/bar.zig");
