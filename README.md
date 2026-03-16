# mir-x11

Low-level X11 protocol client library for Zig.

Communicates directly with the X server via Unix socket -- no dependency on libX11 or libxcb. Provides typed protocol structs that map directly to the X11 wire format, so you can send requests and receive events without any C bindings.

> Most users should prefer [mir-anywindow](../mir-anywindow) for cross-platform window management. Use mir-x11 directly only when you need low-level X11 protocol access.

## Features

- Direct socket connection to the X server (reads `DISPLAY`, defaults to `:0`)
- Setup info retrieval (screens, depths, visual types, formats)
- X11 ID (XID) generation from setup resource masks
- Typed protocol structs (`extern struct`) for requests, replies, and events
- Image format conversion (RGBA to ZPixmap), including a streaming reader
- Atom interning and client message utilities
- Send/receive helpers for the X11 wire protocol with automatic length and padding

## Usage

### Install

```sh
zig fetch --save git+https://github.com/make-it-render/mir-x11
```

### build.zig

```zig
const x11_dep = b.dependency("z11", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("x11", x11_dep.module("x11"));
```

### Example

Based on [src/demo.zig](src/demo.zig):

```zig
const std = @import("std");
const x11 = @import("x11");

// Connect to the X server
const conn = try x11.connect(.{});
defer conn.close();

// Retrieve setup info (screens, formats, resource IDs)
const info = try x11.setup(allocator, conn);
defer info.deinit();

// Initialize ID generator from setup masks
var xid = x11.XID.init(info.resource_id_base, info.resource_id_mask);

// Intern atoms for window manager integration
const wm_name_atom = try x11.internAtom(conn, "WM_NAME");
const wm_delete_window_atom = try x11.internAtom(conn, "WM_DELETE_WINDOW");

// Create a window
const window_id = try xid.genID();
const event_masks = [_]x11.proto.EventMask{ .Exposure, .StructureNotify, .KeyPress };
const window_values = x11.proto.WindowValue{
    .BackgroundPixel = info.screens[0].black_pixel,
    .EventMask = x11.mask(&event_masks),
    .Colormap = info.screens[0].colormap,
};
const create_window = x11.proto.CreateWindow{
    .window_id = window_id,
    .parent_id = info.screens[0].root,
    .visual_id = info.screens[0].root_visual,
    .depth = info.screens[0].root_depth,
    .x = 10, .y = 10, .width = 480, .height = 240,
    .border_width = 0,
    .window_class = .InputOutput,
    .value_mask = x11.maskFromValues(x11.proto.WindowMask, window_values),
};
try x11.sendWithValues(conn, create_window, window_values);

// Map and show the window
try x11.send(conn, x11.proto.MapWindow{ .window_id = window_id });

// Event loop
var open = true;
while (open) {
    while (try x11.receive(conn)) |message| {
        switch (message) {
            .Expose => {
                // Clear and redraw
                try x11.send(conn, x11.proto.ClearArea{ .window_id = window_id });
                // Copy pixmap to window, etc.
            },
            .ClientMessage => |cm| {
                const data = x11.clientMessageData(cm);
                if (data.u32[0] == wm_delete_window_atom) open = false;
            },
            else => {},
        }
    }
}
```

For a complete working example with image drawing and pixel conversion, see [src/demo.zig](src/demo.zig).

## API

### Connection

`x11.connect(options)` opens a Unix socket to the local X server. Returns a `std.net.Stream`.

```zig
const conn = try x11.connect(.{});           // default timeouts
const conn = try x11.connect(.{ .read_timeout = 10000 }); // 10ms read timeout
```

### Setup

`x11.setup(allocator, conn)` performs the X11 handshake and returns a `Setup` with screen info, pixel formats, and resource ID masks.

```zig
const info = try x11.setup(allocator, conn);
defer info.deinit();

const screen = info.screens[0];
// screen.root, screen.root_depth, screen.root_visual, screen.black_pixel, ...
```

### XID

`x11.XID` generates sequential resource IDs for windows, pixmaps, and graphic contexts.

```zig
var xid = x11.XID.init(info.resource_id_base, info.resource_id_mask);
const window_id = try xid.genID();
const pixmap_id = try xid.genID();
```

### Protocol (`x11.proto`)

Typed `extern struct` definitions for all X11 requests, replies, and events. Structs serialize directly to the wire format.

**Requests:** `CreateWindow`, `MapWindow`, `CreatePixmap`, `PutImage`, `CopyArea`, `CreateGraphicContext`, `ChangeProperty`, `ClearArea`, `InternAtom`, `SendEvent`, `DestroyWindow`, `FreePixmap`, `FreeGraphicContext`, and more.

**Events/Messages:** Received via `x11.receive(conn)` which returns a `Message` union:

| Message | Description |
|---------|-------------|
| `.Expose` | Window needs redrawing |
| `.KeyPress` / `.KeyRelease` | Keyboard events |
| `.ButtonPress` / `.ButtonRelease` | Mouse button events |
| `.MotionNotify` | Mouse movement |
| `.ConfigureNotify` | Window resize/move |
| `.ClientMessage` | Inter-client messages (e.g. window close) |
| `.MapNotify` / `.UnmapNotify` | Window visibility changes |

### Sending requests

```zig
// Simple request (no extra data)
try x11.send(conn, x11.proto.MapWindow{ .window_id = window_id });

// Request with extra bytes (auto-pads to 4-byte boundary)
try x11.sendWithBytes(conn, change_property, "hello");

// Request with value-mask pattern (CreateWindow, CreateGraphicContext, ...)
try x11.sendWithValues(conn, create_window, window_values);

// Streaming send from a reader (for large image data)
try x11.stream(writer, put_image_req, pixmap_reader.interface(), pixel_len);
```

### Image conversion

X11 expects pixels in ZPixmap format (BGRX), not RGBA. The `image` module converts between them.

```zig
const image_info = x11.getImageInfo(info, screen.root);

// Allocate a new converted buffer
const zpixmap = try x11.rgbaToZPixmapAlloc(allocator, image_info, &rgba_pixels);
defer allocator.free(zpixmap);

// Or convert in place
try x11.rgbaToZPixmapInPlace(image_info, pixel_buf);

// Or use the streaming reader for large images
var reader = std.Io.Reader.fixed(&rgba_pixels);
var zpixmap_reader = x11.RgbaToZPixmapReader.init(image_info, &reader);
```

### Utilities

```zig
// Intern an atom by name
const atom = try x11.internAtom(conn, "WM_NAME");

// Build event masks from enum values
const mask = x11.mask(&[_]x11.proto.EventMask{ .Exposure, .KeyPress });

// Build value masks from struct fields
const vmask = x11.maskFromValues(x11.proto.WindowMask, window_values);

// Parse client message data
const data = x11.clientMessageData(client_message);
```

## Building

```sh
zig build          # build library and demo
zig build run      # run the demo
zig build test     # run tests
zig build docs     # generate documentation
```

## License

MIT License

Copyright (c) Diogo Souza da Silva
