pub fn bar(x: u32) u32 {
    @import("std").debug.print("hi!", .{});
    return x + 7;
}
