//! Functions get authentication information to connect to X11 server.
//! Currently only supports MIT-MAGIC-COOKIE.

const std = @import("std");

const log = std.log.scoped(.x11);

/// Looks for the Xauthority file and open it.
/// Calee should close it after use.
fn open_xauth_file() !std.fs.File {
    if (std.posix.getenv("XAUTHORITY")) |file| {
        log.debug("Xauthority file: {s}", .{file});
        return std.fs.openFileAbsolute(file, .{});
    } else if (std.posix.getenv("HOME")) |home| {
        var dir = try std.fs.openDirAbsolute(home, .{});
        defer dir.close();
        log.debug("Xauthority file: {s}/.Xauthority", .{home});
        return dir.openFile(".Xauthority", .{});
    } else {
        return error.NoAuthorityFileFound;
    }
}

/// Reads the authority file.
/// Only supports MIT-MAGIC-COOKIE method.
/// Ignore address and port, only support local method.
fn read_xauth_file(allocator: std.mem.Allocator, xauth_file: std.fs.File) !XAuth {
    var buffer: [1024]u8 = undefined;

    var xauth_file_reader = xauth_file.reader(&buffer);
    const xauth_reader = &xauth_file_reader.interface;

    while (true) {
        // Skip family (2 bytes)
        xauth_reader.discardAll(2) catch return error.NoSupportedAuthFound;
        // Skip address
        const address_len = xauth_reader.takeInt(u16, .big) catch return error.NoSupportedAuthFound;
        xauth_reader.discardAll(address_len) catch return error.NoSupportedAuthFound;
        // Skip display number
        const number_len = xauth_reader.takeInt(u16, .big) catch return error.NoSupportedAuthFound;
        xauth_reader.discardAll(number_len) catch return error.NoSupportedAuthFound;

        const xauth_name_len = xauth_reader.takeInt(u16, .big) catch return error.NoSupportedAuthFound;
        if (xauth_name_len > 256) return error.InvalidAuthFile;
        const xauth_name = try allocator.alloc(u8, xauth_name_len);
        xauth_reader.readSliceAll(xauth_name) catch {
            allocator.free(xauth_name);
            return error.NoSupportedAuthFound;
        };

        const xauth_data_len = xauth_reader.takeInt(u16, .big) catch {
            allocator.free(xauth_name);
            return error.NoSupportedAuthFound;
        };
        if (xauth_data_len > 1024) {
            allocator.free(xauth_name);
            return error.InvalidAuthFile;
        }
        const xauth_data = try allocator.alloc(u8, xauth_data_len);
        xauth_reader.readSliceAll(xauth_data) catch {
            allocator.free(xauth_name);
            allocator.free(xauth_data);
            return error.NoSupportedAuthFound;
        };

        if (std.mem.eql(u8, xauth_name, "MIT-MAGIC-COOKIE-1")) {
            log.debug("Auth name: {s}", .{xauth_name});
            return .{ .name = xauth_name, .data = xauth_data, .allocator = allocator };
        }

        // Wrong method — free and try next entry
        allocator.free(xauth_name);
        allocator.free(xauth_data);
    }
}

/// Authentication information
pub const XAuth = struct {
    name: []const u8,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: @This()) void {
        // Zero sensitive auth data before freeing
        @memset(@constCast(self.data), 0);
        @memset(@constCast(self.name), 0);
        self.allocator.free(self.name);
        self.allocator.free(self.data);
    }
};

/// Return authentication information.
/// It will look at XAUTHORITY env var for location of Xauthority file, next it will look for it at HOME.
/// It returns an XAuth struct that needs to be deinit'd after use.
pub fn get_auth(allocator: std.mem.Allocator) !XAuth {
    const xauth_file = try open_xauth_file();
    defer xauth_file.close();
    const xauth = try read_xauth_file(allocator, xauth_file);
    return xauth;
}
