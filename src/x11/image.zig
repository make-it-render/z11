//! Functions to help handle image format for X11.

/// Minimal information to be able to convert to/from an X11 image format.
pub const ImageInfo = struct {
    /// Visual type holds information about how to mask RGB values.
    /// Used to convert from RGB to XPixmap, for example.
    visual_type: proto.VisualType,
    /// Format holds how many bits per pixel, and scanpad value.
    format: proto.Format,
};

/// Given a Setup response, extract needed Image information for working with images.
pub fn getImageInfo(info: xsetup.Setup, root: u32) ImageInfo {
    const target_depth = info.screens[0].root_depth;

    // Find the format of the target root window/display.
    var format_index: usize = 0;
    for (info.formats, 0..) |iformat, index| {
        if (iformat.depth == target_depth) {
            format_index = index;
        }
    }
    const format = info.formats[format_index];

    // Find the screen of the target root window/display.
    // Used to find the allowed_depth.
    var screen_index: usize = 0;
    for (info.screens, 0..) |iscreen, index| {
        if (iscreen.root == root) {
            screen_index = index;
        }
    }
    const screen = info.screens[screen_index];

    // Find the allowed depth of the target root window/display.
    // Used to find the visual type.
    var depth_index: usize = 0;
    for (screen.allowed_depths, 0..) |idepth, index| {
        if (idepth.depth == target_depth) {
            depth_index = index;
        }
    }
    const allowed_depth = screen.allowed_depths[depth_index];

    // Find the visual type of the target root window/display.
    const target_visual_id = screen.root_visual;
    var visual_type_index: usize = 0;
    for (allowed_depth.visual_types, 0..) |ivisual_type, index| {
        if (ivisual_type.visual_id == target_visual_id) {
            visual_type_index = index;
        }
    }
    const visual_type = allowed_depth.visual_types[visual_type_index];

    return .{
        .visual_type = visual_type,
        .format = format,
    };
}

/// Convert an RGBa byte array to a ZPixmap byte array.
/// RGBa format is expected to be in quads of u8.
/// Alpha is ignored.
/// Return a new slice owned by caller.
pub fn rgbaToZPixmapAlloc(allocator: std.mem.Allocator, info: ImageInfo, rgba: []const u8) ![]const u8 {
    const pixels = try allocator.dupe(u8, rgba);
    try rgbaToZPixmapInPlace(info, pixels);
    return pixels;
}

/// Convert an RGBa byte array to a ZPixmap byte array.
/// RGBa format is expected to be in quads of u8.
/// Alpha is ignored.
/// Replaces values in the provided slice.
pub fn rgbaToZPixmapInPlace(info: ImageInfo, pixels: []u8) !void {
    // Only support a very specific visual type and format for now
    if (info.visual_type.class != .TrueColor) {
        return error.UnsupportedVisualTypeClass;
    }
    if (info.format.bits_per_pixel != 32) {
        return error.UnsupportedBitsPerPixel;
    }
    if (info.format.bits_per_pixel != info.format.scanline_pad) {
        return error.UnsupportedScanlinePad;
    }

    rgbaToZPixmap(pixels);
}

fn rgbaToZPixmap(pixels: []u8) void {
    std.debug.assert(pixels.len % 4 == 0);
    var idx: usize = 0;
    while (idx < pixels.len) : (idx += 4) {
        const b = pixels[idx + 2];
        const g = pixels[idx + 1];
        const r = pixels[idx];
        pixels[idx] = b;
        pixels[idx + 1] = g;
        pixels[idx + 2] = r;
        pixels[idx + 3] = 0;
    }
}

pub const RgbaToZPixmapReader = struct {
    reader: *std.Io.Reader,

    interface_state: std.Io.Reader,

    buffer: [1024]u8 = undefined,

    pub fn init(_: ImageInfo, reader: *std.Io.Reader) @This() {
        return .{
            .reader = reader,

            .interface_state = .{
                .vtable = &.{
                    .stream = @This().rgbaToZPixmapStream,
                },
                .buffer = &[0]u8{},
                .end = 0,
                .seek = 0,
            },
        };
    }

    pub fn interface(self: *@This()) *std.Io.Reader {
        return &self.interface_state;
    }

    fn rgbaToZPixmapStream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("interface_state", reader));

        var len: usize = 0;
        while (len < limit.toInt().?) {
            const buffer = limit.subtract(len).?.slice(&self.buffer);
            try self.reader.readSliceAll(buffer);
            rgbaToZPixmap(buffer);
            if (buffer.len != 0) {
                try writer.writeAll(buffer);
                len += buffer.len;
            } else {
                break;
            }
        }
        return len;
    }
};

const std = @import("std");
const xsetup = @import("setup.zig");
const proto = @import("proto.zig");

const log = std.log.scoped(.x11);

test "rgbaToZPixmap swaps R and B channels" {
    const testing = std.testing;

    // RGBA pixels: Red, Green, Blue, White
    var pixels = [_]u8{
        255, 0, 0, 255, // Red (R=255, G=0, B=0, A=255)
        0, 255, 0, 255, // Green (R=0, G=255, B=0, A=255)
        0, 0, 255, 255, // Blue (R=0, G=0, B=255, A=255)
        255, 255, 255, 255, // White (R=255, G=255, B=255, A=255)
    };

    rgbaToZPixmap(&pixels);

    // Expected: BGRA format with alpha zeroed
    const expected = [_]u8{
        0, 0, 255, 0, // Red becomes (B=0, G=0, R=255, A=0)
        0, 255, 0, 0, // Green stays (B=0, G=255, R=0, A=0)
        255, 0, 0, 0, // Blue becomes (B=255, G=0, R=0, A=0)
        255, 255, 255, 0, // White (B=255, G=255, R=255, A=0)
    };

    try testing.expectEqualSlices(u8, &expected, &pixels);
}

test "rgbaToZPixmap handles single pixel" {
    const testing = std.testing;

    var pixels = [_]u8{ 100, 150, 200, 50 };
    rgbaToZPixmap(&pixels);

    // R and B swapped, alpha zeroed
    try testing.expectEqualSlices(u8, &[_]u8{ 200, 150, 100, 0 }, &pixels);
}

test "rgbaToZPixmap handles empty slice" {
    const testing = std.testing;

    var pixels = [_]u8{};
    rgbaToZPixmap(&pixels);

    try testing.expectEqual(@as(usize, 0), pixels.len);
}

test "rgbaToZPixmapAlloc creates new allocation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const info = ImageInfo{
        .visual_type = .{
            .visual_id = 0,
            .class = .TrueColor,
            .bits_per_rgb_value = 8,
            .colormap_entries = 256,
            .red_mask = 0xff0000,
            .green_mask = 0x00ff00,
            .blue_mask = 0x0000ff,
            .pad = [_]u8{0} ** 4,
        },
        .format = .{
            .depth = 24,
            .bits_per_pixel = 32,
            .scanline_pad = 32,
            .pad = [_]u8{0} ** 5,
        },
    };

    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    const result = try rgbaToZPixmapAlloc(allocator, info, &rgba);
    defer allocator.free(result);

    // Verify conversion happened
    const expected = [_]u8{ 0, 0, 255, 0, 0, 255, 0, 0 };
    try testing.expectEqualSlices(u8, &expected, result);
}

test "rgbaToZPixmapInPlace rejects non-TrueColor" {
    const testing = std.testing;

    const info = ImageInfo{
        .visual_type = .{
            .visual_id = 0,
            .class = .StaticGray,
            .bits_per_rgb_value = 8,
            .colormap_entries = 256,
            .red_mask = 0,
            .green_mask = 0,
            .blue_mask = 0,
            .pad = [_]u8{0} ** 4,
        },
        .format = .{
            .depth = 24,
            .bits_per_pixel = 32,
            .scanline_pad = 32,
            .pad = [_]u8{0} ** 5,
        },
    };

    var pixels = [_]u8{ 255, 0, 0, 255 };
    try testing.expectError(error.UnsupportedVisualTypeClass, rgbaToZPixmapInPlace(info, &pixels));
}

test "rgbaToZPixmapInPlace rejects non-32bpp" {
    const testing = std.testing;

    const info = ImageInfo{
        .visual_type = .{
            .visual_id = 0,
            .class = .TrueColor,
            .bits_per_rgb_value = 8,
            .colormap_entries = 256,
            .red_mask = 0xff0000,
            .green_mask = 0x00ff00,
            .blue_mask = 0x0000ff,
            .pad = [_]u8{0} ** 4,
        },
        .format = .{
            .depth = 16,
            .bits_per_pixel = 16,
            .scanline_pad = 16,
            .pad = [_]u8{0} ** 5,
        },
    };

    var pixels = [_]u8{ 255, 0, 0, 255 };
    try testing.expectError(error.UnsupportedBitsPerPixel, rgbaToZPixmapInPlace(info, &pixels));
}
