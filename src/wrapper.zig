/// Helper for mutating code before building it with the Zig compiler
/// `modules` should be a struct literal containing modules of the form:
/// ```
/// .module_name = "zig source code",
/// ```
// TODO: refine this error set
pub fn main(comptime modules: anytype, comptime handlers: anytype) fn () anyerror!u8 {
    const module_names = std.meta.fieldNames(@TypeOf(modules));

    comptime var module_sources: [module_names.len][]const u8 = undefined;
    for (&module_sources, module_names) |*src, name| {
        src.* = @field(modules, name);
    }

    comptime var module_namespaced_names: [module_names.len][]const u8 = undefined;
    for (&module_namespaced_names, module_names) |*ns_name, name| {
        ns_name.* = std.fmt.comptimePrint("{s}.{s}", .{ zik.namespace, name });
    }

    comptime var module_filenames: [module_names.len][]const u8 = undefined;
    for (&module_filenames, module_names) |*fname, name| {
        fname.* = std.fmt.comptimePrint("{s}.zig", .{name});
    }

    comptime var module_relpaths: [module_names.len][]const u8 = undefined;
    for (&module_relpaths, module_filenames) |*path, fname| {
        path.* = std.fmt.comptimePrint("../mod/{s}", .{fname});
    }

    return struct {
        fn actualMain() !u8 {
            // TODO: arena may be really shit here because we're using lots of arraylists
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            // Iterate up the dir tree to find the build.zig
            var source_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
            defer source_dir.close();
            search_for_build: while (true) {
                var it = source_dir.iterateAssumeFirstIteration();
                while (try it.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.name, "build.zig")) {
                        break :search_for_build;
                    }
                }
                var child_dir = source_dir;
                source_dir = try source_dir.openDir("..", .{ .iterate = true });
                child_dir.close();
            }

            const output_path = "zig-cache/tmp/zik";
            var output_dir = try std.fs.cwd().makeOpenPath(output_path, .{});
            defer output_dir.close();

            // TODO: support multiple concurrent builds in the same dir
            const lock_file = output_dir.createFile("lock", .{
                .exclusive = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    std.log.err("Another ZIK process is running, or the lock file has been abandoned", .{});
                    std.log.info("If you are sure no other ZIK process is running, you can remove the lock file at zig-cache/tmp/zik/lock", .{});
                    return 2;
                },
                else => |e| return e,
            };
            lock_file.close();
            defer output_dir.deleteFile("lock") catch |err| {
                std.log.err("Failed to remove lock file: {s}", .{@errorName(err)});
            };

            // Remove old output dir contents
            try output_dir.deleteTree("src");
            try output_dir.deleteTree("mod");

            // Write module sources to disk
            {
                var mod_dir = try output_dir.makeOpenPath("mod", .{});
                defer mod_dir.close();
                for (module_filenames, module_sources) |fname, src| {
                    try mod_dir.writeFile2(.{
                        .sub_path = fname,
                        .data = src,
                    });
                }
            }

            // Mutate the source code
            var dest_dir = try output_dir.makeOpenPath("src", .{});
            defer dest_dir.close();
            try zik.mutateTree(.{
                .allocator = arena.allocator(),
                .dest_dir = dest_dir,
                .source_dir = source_dir,
            }, handlers);

            // Create zig command
            var cmd = std.ArrayList([]const u8).init(arena.allocator());
            defer cmd.deinit();
            try cmd.append("zig"); // TODO: make the zig binary configurable

            var args = try std.process.argsWithAllocator(arena.allocator());
            defer args.deinit();
            _ = args.skip();

            if (args.next()) |subcommand| {
                try cmd.append(subcommand);

                const compile_cmds = std.ComptimeStringMap(void, .{
                    .{"build-exe"},
                    .{"build-lib"},
                    .{"build-obj"},
                    .{"test"},
                    .{"run"},
                });
                if (compile_cmds.get(subcommand)) |_| {
                    // TODO: inject into all modules, not just root
                    try injectDependencies(&cmd);

                    while (args.next()) |arg| {
                        if (std.ascii.endsWithIgnoreCase(arg, ".zig") and arg[0] != '-') {
                            // Hopefully this is a positional argument
                            // If not I will cry because then I have to reimplement the whole Zig arg parser

                            // Turn it into a module definition
                            try cmd.appendSlice(&.{ "--mod", "root", arg });

                            // Inject our modules
                            try injectModules(&cmd);
                        } else if (std.mem.startsWith(u8, arg, "-M") or std.mem.eql(u8, arg, "--mod")) {
                            // End of root module, inject our modules here
                            try cmd.append(arg);
                            try injectModules(&cmd);
                            break;
                        } else {
                            try cmd.append(arg);
                        }
                    } else {
                        // If we've not injected modules by this point, there's no Zig files being compiled so no point anyway
                        // Do nothing
                    }
                } else if (std.mem.eql(u8, subcommand, "build")) {
                    @panic("TODO: support `zig build` in zik.wrapper");
                }

                // Pass through remaining args transparently
                while (args.next()) |arg| {
                    try cmd.append(arg);
                }
            }

            // Run the build
            var proc = std.ChildProcess.init(cmd.items, arena.allocator());
            proc.cwd_dir = dest_dir; // TODO: adjust for relative path
            try proc.spawn();

            switch (try proc.wait()) {
                .Exited => |code| {
                    if (code != 0) {
                        return code;
                    }
                },
                .Signal, .Stopped, .Unknown => {
                    std.log.err("zig terminated unexpectedly", .{});
                    return 1;
                },
            }

            return 0;
        }

        fn injectDependencies(cmd: *std.ArrayList([]const u8)) !void {
            for (module_namespaced_names) |ns_name| {
                try cmd.appendSlice(&.{ "--dep", ns_name });
            }
        }
        fn injectModules(cmd: *std.ArrayList([]const u8)) !void {
            for (module_namespaced_names, module_relpaths) |ns_name, path| {
                try cmd.appendSlice(&.{ "--mod", ns_name, path });
            }
        }
    }.actualMain;
}

const std = @import("std");
const zik = @import("root.zig");
