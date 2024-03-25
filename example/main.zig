pub fn main() void {
    foo();
    bar();
}

fn foo() void {
    bar();
}

fn bar() void {}

const std = @import("std");
