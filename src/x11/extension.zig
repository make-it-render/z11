//! Negotiating X11 extensions.
//!
//! Extensions are not compiled into the wire protocol at fixed opcodes: the server assigns
//! each one a major opcode, a first event code and a first error code per connection. Every
//! extension request is `{ major_opcode, minor_opcode, ... }`, so the major opcode has to be
//! looked up at runtime before any extension request can be built.

const std = @import("std");
const proto = @import("proto.zig");
const io = @import("io.zig");
const utils = @import("utils.zig");

const testing = std.testing;
const endian = @import("builtin").cpu.arch.endian();

const log = std.log.scoped(.x11);

pub const Error = error{
    /// The server did not return a valid reply for a QueryExtension request.
    QueryExtensionFailed,
};

/// The dynamic bases the server assigned to an extension on this connection.
pub const Extension = struct {
    /// False when the server does not have the extension. The other fields are meaningless.
    present: bool,
    /// First byte of every request belonging to this extension.
    major_opcode: u8,
    /// Event codes for this extension start here.
    first_event: u8,
    /// Error codes for this extension start here.
    first_error: u8,

    /// Whether `event_code` (as received from io.Message.Generic) belongs to this extension.
    /// Only meaningful for extensions with a known event count; `offset` is the extension's
    /// own event number (ShmCompletion is 0).
    pub fn isEvent(self: @This(), event_code: u8, offset: u8) bool {
        return self.present and event_code == self.first_event + offset;
    }
};

/// Negotiate an extension by name.
/// This is naive because it expects the next message to always be the reply, the same
/// constraint as utils.internAtom: call it during init, before an event loop starts
/// reading from the connection.
pub fn queryExtension(io_inst: std.Io, conn: std.Io.net.Stream, name: []const u8) (io.Error || utils.Error || Error)!Extension {
    const request = proto.QueryExtension{ .length_of_name = @intCast(name.len) };
    try io.sendWithBytes(io_inst, conn, request, name);

    const reply = try utils.receiveReply(io_inst, conn, proto.QueryExtensionReply) orelse
        return error.QueryExtensionFailed;

    log.debug("Extension {s}: present={d} major={d} first_event={d} first_error={d}", .{
        name,
        reply.present,
        reply.major_opcode,
        reply.first_event,
        reply.first_error,
    });

    return .{
        .present = reply.present != 0,
        .major_opcode = reply.major_opcode,
        .first_event = reply.first_event,
        .first_error = reply.first_error,
    };
}

test "QueryExtensionReply decodes a present extension" {
    // A reply as the server would write it: MIT-SHM granted major 130, events at 65, errors at 128.
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 1; // reply
    bytes[2] = 5; // sequence_number (little end)
    bytes[8] = 1; // present
    bytes[9] = 130; // major_opcode
    bytes[10] = 65; // first_event
    bytes[11] = 128; // first_error

    var reader: std.Io.Reader = .fixed(&bytes);
    const reply = try reader.takeStruct(proto.QueryExtensionReply, endian);

    try testing.expectEqual(@as(u8, 1), reply.present);
    try testing.expectEqual(@as(u8, 130), reply.major_opcode);
    try testing.expectEqual(@as(u8, 65), reply.first_event);
    try testing.expectEqual(@as(u8, 128), reply.first_error);
    try testing.expectEqual(@as(u16, 5), reply.sequence_number);
}

test "QueryExtensionReply decodes an absent extension" {
    // present=0 is how a server without the extension answers; the bases are meaningless.
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 1; // reply

    var reader: std.Io.Reader = .fixed(&bytes);
    const reply = try reader.takeStruct(proto.QueryExtensionReply, endian);

    try testing.expectEqual(@as(u8, 0), reply.present);
}

test "QueryExtension request is 8 bytes" {
    // 2 words: the wire length before sendWithBytes extends it to cover the name.
    try testing.expectEqual(@as(usize, 8), @sizeOf(proto.QueryExtension));
    const request = proto.QueryExtension{ .length_of_name = 7 };
    try testing.expectEqual(@as(u8, 98), request.opcode);
    try testing.expectEqual(@as(u16, 2), request.length);
}

test "isEvent matches only the extension's own codes" {
    const ext = Extension{ .present = true, .major_opcode = 130, .first_event = 65, .first_error = 128 };
    try testing.expect(ext.isEvent(65, 0));
    try testing.expect(!ext.isEvent(66, 0));
    try testing.expect(!ext.isEvent(12, 0));

    // An absent extension owns no event codes, whatever first_event happens to hold.
    const absent = Extension{ .present = false, .major_opcode = 0, .first_event = 65, .first_error = 0 };
    try testing.expect(!absent.isEvent(65, 0));
}
