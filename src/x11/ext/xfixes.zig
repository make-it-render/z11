//! XFixes: the selection-owner notifications the core protocol lacks.
//!
//! Core X11 tells a client only about the selections it loses (SelectionClear). A client that
//! wants to know when *anyone* claims CLIPBOARD — to enable a paste button, say — has to ask
//! XFixes for a SelectionNotify event on every owner change.
//!
//! Every request here starts with `major_opcode`, which the server assigns per-connection: fill it
//! from `probe` (which also runs the QueryVersion handshake the server insists on before it accepts
//! any other XFixes request).

const std = @import("std");
const proto = @import("../proto.zig");
const io = @import("../io.zig");
const utils = @import("../utils.zig");
const extension = @import("../extension.zig");

const testing = std.testing;

const log = std.log.scoped(.x11);

pub const Error = error{
    /// The server did not return a valid reply for a QueryExtension request.
    QueryExtensionFailed,
};

/// The name to hand queryExtension.
pub const extension_name = "XFIXES";

/// The version this client speaks. SelectSelectionInput exists since 1.0; nothing here needs more.
pub const client_major_version = 5;
pub const client_minor_version = 0;

/// This extension's own event numbers, added to Extension.first_event.
pub const Event = struct {
    pub const selection_notify = 0;
    pub const cursor_notify = 1;
};

/// This extension's own minor opcodes.
pub const Opcode = struct {
    pub const query_version = 0;
    pub const change_save_set = 1;
    pub const select_selection_input = 2;
    pub const select_cursor_input = 3;
    pub const get_cursor_image = 4;
};

/// Which owner changes SelectSelectionInput reports; OR them into `event_mask`.
pub const SelectionEventMask = struct {
    /// A client claimed the selection (SetSelectionOwner).
    pub const set_selection_owner: u32 = 1;
    /// The owning window was destroyed.
    pub const selection_window_destroy: u32 = 2;
    /// The owning client disconnected.
    pub const selection_client_close: u32 = 4;
};

/// The `subtype` of a SelectionNotify; one per SelectionEventMask bit.
pub const SelectionEventSubtype = enum(u8) {
    set_selection_owner = 0,
    selection_window_destroy = 1,
    selection_client_close = 2,
    _,
};

/// The server refuses every other XFixes request from a client that has not sent this.
pub const QueryVersion = extern struct {
    major_opcode: u8,
    minor_opcode: u8 = Opcode.query_version,
    length: u16 = @sizeOf(@This()) / 4,
    client_major_version: u32 = client_major_version,
    client_minor_version: u32 = client_minor_version,
};

pub const QueryVersionReply = extern struct {
    reply: u8,
    unused: u8,
    sequence_number: u16,
    reply_length: u32,
    major_version: u32,
    minor_version: u32,
    unused2: [16]u8,
};

/// Ask for a SelectionNotify, delivered as an event on `window`, whenever `selection` changes
/// hands in one of the ways `event_mask` names. A zero mask cancels the request.
pub const SelectSelectionInput = extern struct {
    major_opcode: u8,
    minor_opcode: u8 = Opcode.select_selection_input,
    length: u16 = @sizeOf(@This()) / 4,
    window: u32,
    selection: u32,
    event_mask: u32,
};

/// `selection` changed owner; `owner` is the new one (0 once it went away). Arrives on the
/// normal message stream with a runtime code, so it surfaces as io.Message.Generic; match
/// `code` against `Extension.first_event + Event.selection_notify` and decode with `as`.
pub const SelectionNotify = extern struct {
    code: u8,
    subtype: SelectionEventSubtype,
    sequence_number: u16,
    /// The window named in SelectSelectionInput.
    window: u32,
    owner: u32,
    selection: u32,
    /// Server time of the change.
    timestamp: u32,
    /// The time the new owner claimed the selection with.
    selection_timestamp: u32,
    unused: [8]u8,
};

// The server reads these off the wire by size; a wrong one is a desync, not a type error.
comptime {
    std.debug.assert(@sizeOf(QueryVersion) == 12);
    std.debug.assert(@sizeOf(QueryVersionReply) == 32);
    std.debug.assert(@sizeOf(SelectSelectionInput) == 16);
    std.debug.assert(@sizeOf(SelectionNotify) == 32);
}

/// Negotiate XFixes. Returns null when the server lacks it or predates version 1 (the one that
/// introduced SelectSelectionInput) — callers treat that as "no owner-change events", never as
/// an error. Naive reply read: call during init, before an event loop starts.
pub fn probe(io_inst: std.Io, conn: std.Io.net.Stream) (io.Error || utils.Error || extension.Error || Error)!?extension.Extension {
    const ext = try extension.queryExtension(io_inst, conn, extension_name);
    if (!ext.present) {
        log.debug("XFixes not present; no selection-owner events", .{});
        return null;
    }

    try io.send(io_inst, conn, QueryVersion{ .major_opcode = ext.major_opcode });
    const reply = try utils.receiveReply(io_inst, conn, QueryVersionReply) orelse return null;
    if (reply.major_version < 1) {
        log.debug("XFixes {d}.{d} predates SelectSelectionInput; no selection-owner events", .{ reply.major_version, reply.minor_version });
        return null;
    }

    log.debug("XFixes {d}.{d} ready", .{ reply.major_version, reply.minor_version });
    return ext;
}

/// Subscribe to owner changes of `selection`, reported on `window`; see SelectSelectionInput.
pub fn selectSelectionInput(io_inst: std.Io, conn: std.Io.net.Stream, ext: extension.Extension, window: u32, selection: u32, event_mask: u32) io.Error!void {
    std.debug.assert(ext.present);
    try io.send(io_inst, conn, SelectSelectionInput{
        .major_opcode = ext.major_opcode,
        .window = window,
        .selection = selection,
        .event_mask = event_mask,
    });
}

test "request sizes match the wire format" {
    // Lengths are in 4-byte words and are what the server uses to frame the next request.
    try testing.expectEqual(@as(u16, 3), (QueryVersion{ .major_opcode = 137 }).length);
    try testing.expectEqual(@as(u16, 4), (SelectSelectionInput{ .major_opcode = 137, .window = 1, .selection = 2, .event_mask = 1 }).length);
}

test "SelectSelectionInput lays out where the server expects" {
    const request = SelectSelectionInput{
        .major_opcode = 137,
        .window = 0x11223344,
        .selection = 0x1F1,
        .event_mask = SelectionEventMask.set_selection_owner | SelectionEventMask.selection_client_close,
    };
    const bytes = std.mem.toBytes(request);

    try testing.expectEqual(@as(u8, 137), bytes[0]);
    try testing.expectEqual(@as(u8, Opcode.select_selection_input), bytes[1]);
    try testing.expectEqual(@as(u32, 0x11223344), std.mem.bytesToValue(u32, bytes[4..8]));
    try testing.expectEqual(@as(u32, 0x1F1), std.mem.bytesToValue(u32, bytes[8..12]));
    try testing.expectEqual(@as(u32, 5), std.mem.bytesToValue(u32, bytes[12..16]));
}

test "QueryVersion announces the version this client speaks" {
    const bytes = std.mem.toBytes(QueryVersion{ .major_opcode = 137 });
    try testing.expectEqual(@as(u8, Opcode.query_version), bytes[1]);
    try testing.expectEqual(@as(u32, client_major_version), std.mem.bytesToValue(u32, bytes[4..8]));
    try testing.expectEqual(@as(u32, client_minor_version), std.mem.bytesToValue(u32, bytes[8..12]));
}

test "SelectionNotify decodes from a raw generic event" {
    // What the reader task actually gets: 32 bytes with a runtime code.
    const first_event: u8 = 86;
    var bytes = [_]u8{0} ** 32;
    bytes[0] = first_event + Event.selection_notify;
    bytes[1] = @intFromEnum(SelectionEventSubtype.set_selection_owner);
    std.mem.writeInt(u32, bytes[4..8], 0x2A3, .little); // window
    std.mem.writeInt(u32, bytes[8..12], 0x400001, .little); // owner
    std.mem.writeInt(u32, bytes[12..16], 0x1F1, .little); // selection
    std.mem.writeInt(u32, bytes[16..20], 1000, .little); // timestamp
    std.mem.writeInt(u32, bytes[20..24], 999, .little); // selection_timestamp

    const generic = std.mem.bytesToValue(io.GenericEvent, &bytes);
    const ext = extension.Extension{ .present = true, .major_opcode = 137, .first_event = first_event, .first_error = 138 };
    try testing.expect(ext.isEvent(generic.code, Event.selection_notify));
    try testing.expect(!ext.isEvent(generic.code, Event.cursor_notify));

    const notify = generic.as(SelectionNotify);
    try testing.expectEqual(SelectionEventSubtype.set_selection_owner, notify.subtype);
    try testing.expectEqual(@as(u32, 0x2A3), notify.window);
    try testing.expectEqual(@as(u32, 0x400001), notify.owner);
    try testing.expectEqual(@as(u32, 0x1F1), notify.selection);
    try testing.expectEqual(@as(u32, 1000), notify.timestamp);
    try testing.expectEqual(@as(u32, 999), notify.selection_timestamp);
}

test "QueryVersionReply decodes the server's version" {
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 1; // reply
    std.mem.writeInt(u32, bytes[8..12], 5, .little); // major_version
    std.mem.writeInt(u32, bytes[12..16], 0, .little); // minor_version

    var reader: std.Io.Reader = .fixed(&bytes);
    const reply = try reader.takeStruct(QueryVersionReply, @import("builtin").cpu.arch.endian());
    try testing.expectEqual(@as(u32, 5), reply.major_version);
    try testing.expectEqual(@as(u32, 0), reply.minor_version);
}

// probe and selectSelectionInput need a live X server, so no test calls them and Zig would never
// analyze their bodies — they would compile-rot silently. Force analysis.
test "probe and select entry points compile" {
    _ = &probe;
    _ = &selectSelectionInput;
}
