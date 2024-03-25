# Zig Instrumentation Kit

A slightly cursed library for source-level static instrumentation in Zig.

This repository also includes a simple function-level profiler that outputs to the [callgrind format](https://valgrind.org/docs/manual/cl-format.html), which is readable by [KCacheGrind](https://kcachegrind.sourceforge.net/html/Home.html).

## Using the profiler

**NOTE: This is currently proof-of-concept quality. Notably, multithreaded programs will not work at all**

Build the profiler using `zig build zikprof`, then run the binary from `zig-out/bin/zikprof` with the same args you'd normally pass to `zig`. (TODO: this does not currently work with `zig build`. Stick to `zig build-exe`, `zig run`, etc)

This will copy your entire source tree, rooted at `build.zig`, into `zig-cache/tmp/zik/src`, instrument it, then run the Zig command as normal. (TODO: this should be more transparent to the user. Build output and program output should be placed in the locations one would expect from running Zig normally)

Here is an example usage:

```
zig build zikprof
cd example
../zig-out/bin/zikprof run main.zig
```

You can then open `example/zig-cache/tmp/zik/src/callgrind.out.zikprof.<PID>` in KCacheGrind to inspect the call graph.
