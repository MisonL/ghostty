# Example: `libghostty` Software Host

This example demonstrates the first cross-platform `libghostty` software-host
surface mode. It creates an embedded surface without an AppKit/UIKit view and
consumes frames through `ghostty_runtime_software_frame_cb`.

The example intentionally forces a shared CPU software-frame transport so it
can run on Linux without any native texture bridge.

## Usage

Build the example:

```shell-session
zig build
```

Run the example:

```shell-session
zig build run
```

On Apple hosts, `zig build run` currently prints an explicit note and exits
after the surface creation attempt, because the software-host frame smoke path
is intended to be exercised on a non-Apple runtime. The real end-to-end smoke
run is wired into Linux CI.
