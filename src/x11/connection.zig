//! Functions to connect to an X11 server.

const std = @import("std");

const log = std.log.scoped(.x11);

/// Options for the X11 connection.
pub const ConnectionOptions = struct {};

/// Connects to local X11 server.
/// It will look for DISPLAY env variable, or default to :0.
pub fn connect(io: std.Io, environ: std.process.Environ, options: ConnectionOptions) !std.Io.net.Stream {
    _ = options;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const socket_path = try get_socket_path(environ, &buffer);

    log.debug("Socket path: {s}", .{socket_path});

    // Assuming unix socket
    const unix_addr = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try unix_addr.connect(io);

    log.debug("Connected", .{});

    return stream;
}

/// Return the file path for the socket to active display.
/// Look at DISPLAY env var for display, else default to :0
/// Uses provided buffer and return only the needed part.
fn get_socket_path(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    const display: []const u8 = environ.getPosix("DISPLAY") orelse ":0";
    log.debug("Display: {s}", .{display});

    // Find colon separator
    const colon_pos = std.mem.indexOfScalar(u8, display, ':') orelse return error.InvalidDisplay;
    var display_num: []const u8 = display[colon_pos + 1 ..];

    // Strip optional screen number (e.g., ":0.0" → "0")
    if (std.mem.indexOfScalar(u8, display_num, '.')) |dot| {
        display_num = display_num[0..dot];
    }

    // Validate: must be non-empty and digits only
    if (display_num.len == 0) return error.InvalidDisplay;
    for (display_num) |c| {
        if (c < '0' or c > '9') return error.InvalidDisplay;
    }

    const base = "/tmp/.X11-unix/X";
    const total = base.len + display_num.len;
    if (buffer.len < total) return error.SocketPathBufferTooSmall;

    var path = buffer[0..total];
    @memcpy(path[0..base.len], base);
    @memcpy(path[base.len..], display_num);
    return path;
}
