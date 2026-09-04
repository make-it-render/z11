//! The XDND drag-and-drop convention (version 5): the atom names both sides intern, and the five-long ClientMessage payloads packed and unpacked. XDND is a convention over core requests, not an extension, so nothing here touches the socket.

/// The protocol version this client speaks.
pub const version: u8 = 5;

/// Atom names, so a source and a target intern the same spellings.
pub const Atom = struct {
    pub const aware = "XdndAware";
    pub const selection = "XdndSelection";
    pub const enter = "XdndEnter";
    pub const position = "XdndPosition";
    pub const status = "XdndStatus";
    pub const leave = "XdndLeave";
    pub const drop = "XdndDrop";
    pub const finished = "XdndFinished";
    pub const type_list = "XdndTypeList";
    pub const proxy = "XdndProxy";
    pub const action_copy = "XdndActionCopy";
    pub const action_move = "XdndActionMove";
    pub const action_link = "XdndActionLink";
};

/// The source announces itself to a target with its protocol version and up to three types; more sit in the source window's `XdndTypeList` property.
pub const Enter = struct {
    source: u32,
    version: u8,
    more_types: bool,
    types: [3]u32,

    pub fn pack(self: @This()) [5]u32 {
        return .{ self.source, (@as(u32, self.version) << 24) | @intFromBool(self.more_types), self.types[0], self.types[1], self.types[2] };
    }

    pub fn unpack(data: [5]u32) @This() {
        return .{
            .source = data[0],
            .version = @truncate(data[1] >> 24),
            .more_types = data[1] & 1 != 0,
            .types = .{ data[2], data[3], data[4] },
        };
    }
};

/// Where the pointer is, in root coordinates, and the action the source proposes.
pub const Position = struct {
    source: u32,
    root_x: i16,
    root_y: i16,
    time: u32,
    action: u32,

    pub fn pack(self: @This()) [5]u32 {
        return .{ self.source, 0, packPoint(self.root_x, self.root_y), self.time, self.action };
    }

    pub fn unpack(data: [5]u32) @This() {
        const point = unpackPoint(data[2]);
        return .{ .source = data[0], .root_x = point[0], .root_y = point[1], .time = data[3], .action = data[4] };
    }
};

/// The target's answer to a position: whether it would take a drop, and where the source may stop sending positions.
pub const Status = struct {
    target: u32,
    accept: bool,
    /// Keep sending positions while the pointer is inside `rect`; with an empty rectangle, on every move.
    send_every_position: bool,
    rect: Rect,
    action: u32,

    pub const Rect = struct { x: i16 = 0, y: i16 = 0, width: u16 = 0, height: u16 = 0 };

    pub fn pack(self: @This()) [5]u32 {
        const flags: u32 = @as(u32, @intFromBool(self.accept)) | (@as(u32, @intFromBool(self.send_every_position)) << 1);
        return .{ self.target, flags, packPoint(self.rect.x, self.rect.y), (@as(u32, self.rect.width) << 16) | self.rect.height, self.action };
    }

    pub fn unpack(data: [5]u32) @This() {
        const origin = unpackPoint(data[2]);
        return .{
            .target = data[0],
            .accept = data[1] & 1 != 0,
            .send_every_position = data[1] & 2 != 0,
            .rect = .{ .x = origin[0], .y = origin[1], .width = @truncate(data[3] >> 16), .height = @truncate(data[3]) },
            .action = data[4],
        };
    }
};

/// The pointer left the target without a drop.
pub const Leave = struct {
    source: u32,

    pub fn pack(self: @This()) [5]u32 {
        return .{ self.source, 0, 0, 0, 0 };
    }

    pub fn unpack(data: [5]u32) @This() {
        return .{ .source = data[0] };
    }
};

/// The button was released over the target: fetch `XdndSelection` with this time.
pub const Drop = struct {
    source: u32,
    time: u32,

    pub fn pack(self: @This()) [5]u32 {
        return .{ self.source, 0, self.time, 0, 0 };
    }

    pub fn unpack(data: [5]u32) @This() {
        return .{ .source = data[0], .time = data[2] };
    }
};

/// The target is done with the selection; since version 5 it says whether it took the drop and with which action.
pub const Finished = struct {
    target: u32,
    accepted: bool,
    action: u32,

    pub fn pack(self: @This()) [5]u32 {
        return .{ self.target, @intFromBool(self.accepted), self.action, 0, 0 };
    }

    pub fn unpack(data: [5]u32) @This() {
        return .{ .target = data[0], .accepted = data[1] & 1 != 0, .action = data[2] };
    }
};

/// `(x << 16) | y`, each half a 16-bit two's complement value.
fn packPoint(x: i16, y: i16) u32 {
    return (@as(u32, @as(u16, @bitCast(x))) << 16) | @as(u16, @bitCast(y));
}

fn unpackPoint(packed_point: u32) [2]i16 {
    return .{ @bitCast(@as(u16, @truncate(packed_point >> 16))), @bitCast(@as(u16, @truncate(packed_point))) };
}

const std = @import("std");
const testing = std.testing;

test "Enter packs the version in the high byte and the type-list flag in bit 0" {
    const enter = Enter{ .source = 0x400001, .version = 5, .more_types = true, .types = .{ 1, 2, 3 } };
    const data = enter.pack();
    try testing.expectEqual(@as(u32, 0x05000001), data[1]);
    try testing.expectEqual(enter, Enter.unpack(data));
    try testing.expect(!Enter.unpack(.{ 0, 0x03000000, 0, 0, 0 }).more_types);
    try testing.expectEqual(@as(u8, 3), Enter.unpack(.{ 0, 0x03000000, 0, 0, 0 }).version);
}

test "Position packs root coordinates as x high, y low, negatives included" {
    const position = Position{ .source = 7, .root_x = -3, .root_y = 1000, .time = 42, .action = 9 };
    const data = position.pack();
    try testing.expectEqual(@as(u32, 0xFFFD03E8), data[2]);
    try testing.expectEqual(@as(u32, 42), data[3]);
    try testing.expectEqual(position, Position.unpack(data));
}

test "Status packs accept in bit 0, the position flag in bit 1 and the rectangle in two longs" {
    const status = Status{ .target = 5, .accept = true, .send_every_position = true, .rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 }, .action = 8 };
    const data = status.pack();
    try testing.expectEqual(@as(u32, 3), data[1]);
    try testing.expectEqual(@as(u32, (10 << 16) | 20), data[2]);
    try testing.expectEqual(@as(u32, (30 << 16) | 40), data[3]);
    try testing.expectEqual(status, Status.unpack(data));
    const refused = Status.unpack(.{ 5, 0, 0, 0, 0 });
    try testing.expect(!refused.accept and !refused.send_every_position);
}

test "Leave, Drop and Finished round-trip" {
    try testing.expectEqual(Leave{ .source = 3 }, Leave.unpack((Leave{ .source = 3 }).pack()));
    const drop = Drop{ .source = 3, .time = 77 };
    try testing.expectEqual(@as(u32, 77), drop.pack()[2]);
    try testing.expectEqual(drop, Drop.unpack(drop.pack()));
    const finished = Finished{ .target = 4, .accepted = true, .action = 6 };
    try testing.expectEqual(@as(u32, 1), finished.pack()[1]);
    try testing.expectEqual(finished, Finished.unpack(finished.pack()));
    try testing.expect(!Finished.unpack(.{ 4, 0, 0, 0, 0 }).accepted);
}
