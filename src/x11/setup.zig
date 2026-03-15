//! After a connection is estibilished, this functions return the Setup.
//! This is expected to be the first messages sent and received on a new connection.
//! It return important information for building Windows and Images.

const std = @import("std");
const xauth = @import("auth.zig");
const proto = @import("proto.zig");

const log = std.log.scoped(.x11);

const endian = @import("builtin").cpu.arch.endian();

/// First function to call on a new connection.
/// It will return important information for most of following requests.
pub fn setup(allocator: std.mem.Allocator, connection: std.net.Stream) !Setup {
    const auth = try xauth.get_auth(allocator);
    defer auth.deinit();

    var read_buffer: [32]u8 = undefined;
    var conn_reader = connection.reader(&read_buffer);
    const reader = conn_reader.interface();

    var write_buffer: [32]u8 = undefined;
    var conn_writer = connection.writer(&write_buffer);
    const writer = &conn_writer.interface;

    try sendSetupRequest(writer, auth.name, auth.data);

    const xdata = try readSetupReply(allocator, reader);

    return xdata;
}

fn sendSetupRequest(writer: *std.Io.Writer, auth_name: []const u8, auth_data: []const u8) !void {
    const request_base = proto.SetupRequest{
        .auth_name_len = @intCast(auth_name.len),
        .auth_data_len = @intCast(auth_data.len),
    };
    try writer.writeAll(&std.mem.toBytes(request_base));

    const pad: [3]u8 = .{ 0, 0, 0 };
    try writer.writeAll(auth_name);
    try writer.writeAll(pad[0..(auth_name.len % 4)]);

    try writer.writeAll(auth_data);
    try writer.writeAll(pad[0..(auth_data.len % 4)]);

    try writer.flush();
}

fn readSetupReply(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Setup {
    const status_reply = try reader.takeStruct(proto.SetupStatus, endian);

    const reply_size = @as(usize, status_reply.reply_len) * 4;
    if (reply_size > 1024 * 1024) return error.SetupDataTooLarge;
    const reply = try allocator.alloc(u8, reply_size);
    defer allocator.free(reply);
    try reader.readSliceAll(reply); // read rest of response

    switch (status_reply.status) {
        0 => return error.SetupFailed,
        1 => {}, // success, continue
        2 => return error.AuthenticationFailed,
        else => return error.InvalidSetupStatus,
    }

    var reply_stream = std.io.fixedBufferStream(reply);
    var reply_reader = reply_stream.reader();

    const base_reply = try reply_reader.readStruct(proto.SetupContent);
    log.debug("Base setup: {any}", .{base_reply});

    if (base_reply.vendor_len > 1024) return error.SetupDataTooLarge;
    const vendor = try allocator.alloc(u8, base_reply.vendor_len);
    defer allocator.free(vendor);
    _ = try reply_reader.read(vendor);
    _ = try reply_reader.skipBytes(vendor.len % 4, .{}); // pad vendor

    if (base_reply.pixmap_formats_len > 256) return error.SetupDataTooLarge;
    const formats = try allocator.alloc(proto.Format, base_reply.pixmap_formats_len);
    errdefer allocator.free(formats);
    for (formats, 0..) |_, format_index| {
        formats[format_index] = try reply_reader.readStruct(proto.Format);
        log.debug("Format: {any}", .{formats[format_index]});
    }

    if (base_reply.roots_len > 64) return error.SetupDataTooLarge;
    const screens = try allocator.alloc(Screen, base_reply.roots_len);
    var screens_initialized: usize = 0;
    errdefer {
        for (screens[0..screens_initialized]) |screen| {
            screen.deinit(allocator);
        }
        allocator.free(screens);
    }

    for (screens, 0..) |_, screen_index| {
        const screen = try reply_reader.readStruct(proto.Screen);
        screens[screen_index] = Screen.initFromProto(screen);
        log.debug("Screen: {any}", .{screens[screen_index]});

        if (screen.allowed_depths_len > 128) return error.SetupDataTooLarge;
        const allowed_depths = try allocator.alloc(Depth, screen.allowed_depths_len);
        var depths_initialized: usize = 0;
        errdefer {
            for (allowed_depths[0..depths_initialized]) |depth| {
                depth.deinit(allocator);
            }
            allocator.free(allowed_depths);
        }

        for (allowed_depths, 0..) |_, depth_index| {
            const depth = try reply_reader.readStruct(proto.Depth);
            allowed_depths[depth_index] = Depth.initFromProto(depth);
            log.debug("Allowed depths: {any}", .{allowed_depths[depth_index]});

            if (depth.visual_type_len > 1024) return error.SetupDataTooLarge;
            const visual_types = try allocator.alloc(proto.VisualType, depth.visual_type_len);
            errdefer allocator.free(visual_types);

            for (visual_types, 0..) |_, visual_type_index| {
                visual_types[visual_type_index] = try reply_reader.readStruct(proto.VisualType);
                log.debug("Visual type: {any}", .{visual_types[visual_type_index]});
            }
            allowed_depths[depth_index].visual_types = visual_types;
            depths_initialized += 1;
        }
        screens[screen_index].allowed_depths = allowed_depths;
        screens_initialized += 1;
    }

    var result = Setup.initFromProto(allocator, base_reply);
    result.screens = screens;
    result.formats = formats;

    return result;
}

/// Setup struct hold information needed for a few requests.
pub const Setup = struct {
    allocator: std.mem.Allocator,

    /// Resoure ID base and mask are used for generating IDs.
    /// For example use IDs of windows, graphical context and pixmaps.
    resource_id_base: u32,
    resource_id_mask: u32,

    maximum_request_length: u16,

    min_keycode: u8,
    max_keycode: u8,

    image_byte_order: proto.ImageByteOrder,
    bitmap_format_bit_order: proto.BitmapFormatBitOrder,
    bitmap_format_scanline_unit: u8,
    bitmap_format_scanline_pad: u8,

    /// Format is used for generating images.
    formats: []const proto.Format = &[_]proto.Format{},
    /// Have information about the screen,
    /// so you can create window and other drawables with the right color space and depth.
    screens: []const Screen = &[_]Screen{},

    pub fn initFromProto(allocator: std.mem.Allocator, reply: proto.SetupContent) @This() {
        return .{
            .allocator = allocator,
            .resource_id_base = reply.resource_id_base,
            .resource_id_mask = reply.resource_id_mask,
            .maximum_request_length = reply.maximum_request_length,
            .min_keycode = reply.min_keycode,
            .max_keycode = reply.max_keycode,
            .image_byte_order = reply.image_byte_order,
            .bitmap_format_bit_order = reply.bitmap_format_bit_order,
            .bitmap_format_scanline_unit = reply.bitmap_format_scanline_unit,
            .bitmap_format_scanline_pad = reply.bitmap_format_scanline_pad,
        };
    }

    pub fn deinit(self: @This()) void {
        for (self.screens) |screen| {
            screen.deinit(self.allocator);
        }
        self.allocator.free(self.screens);
        self.allocator.free(self.formats);
    }
};

/// The screen you will use.
pub const Screen = struct {
    /// The root screen or window, your first window will be on top of this.
    root: u32,
    colormap: u32,
    white_pixel: u32,
    black_pixel: u32,
    root_visual: u32,
    root_depth: u8,
    allowed_depths: []const Depth = &[_]Depth{},

    width_in_pixels: u16,
    height_in_pixels: u16,
    width_in_millimeters: u16,
    height_in_millimeters: u16,

    pub fn initFromProto(screen: proto.Screen) @This() {
        return .{
            .root = screen.root,
            .colormap = screen.colormap,
            .white_pixel = screen.white_pixel,
            .black_pixel = screen.black_pixel,
            .root_visual = screen.root_visual,
            .root_depth = screen.root_depth,
            .width_in_pixels = screen.width_in_pixels,
            .height_in_pixels = screen.height_in_pixels,
            .width_in_millimeters = screen.width_in_millimeters,
            .height_in_millimeters = screen.height_in_millimeters,
        };
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        for (self.allowed_depths) |depth| {
            depth.deinit(allocator);
        }
        allocator.free(self.allowed_depths);
    }
};

/// Depth of the screen.
pub const Depth = struct {
    depth: u8,
    visual_types: []proto.VisualType = &[_]proto.VisualType{},

    pub fn initFromProto(reply: proto.Depth) @This() {
        return .{
            .depth = reply.depth,
        };
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.visual_types);
    }
};
