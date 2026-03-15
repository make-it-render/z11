//! X11 expecte it's client to create some IDs
//! Here we have a function to generate it.

const std = @import("std");

const log = std.log.scoped(.x11);

/// Struct to control ID generation.
/// IDs are somewhat sequencial and finite,
/// so we need to keep track of it.
pub const XID = struct {
    base: u32,
    inc: u32,
    max: u32,

    last: u32 = 0,

    /// Initial values are obtained from Setup.
    pub fn init(resource_id_base: u32, resource_id_mask: u32) @This() {
        const imask: i32 = @bitCast(resource_id_mask);
        const inc = imask & -(imask);

        return .{
            .base = resource_id_base,
            .max = resource_id_mask,
            .inc = @bitCast(inc),
        };
    }

    /// Generate next ID.
    pub fn genID(self: *@This()) !u32 {
        if (self.last == self.max) {
            // TODO: request new range of IDs
            return error.NoMoreIDs;
        } else {
            self.last += self.inc;
        }
        return self.last | self.base;
    }
};

test "XID init calculates increment from mask" {
    const testing = std.testing;

    // Typical X11 mask: 0x001fffff (21 bits for IDs)
    const xid = XID.init(0x04000000, 0x001fffff);
    try testing.expectEqual(@as(u32, 0x04000000), xid.base);
    try testing.expectEqual(@as(u32, 0x001fffff), xid.max);
    try testing.expectEqual(@as(u32, 1), xid.inc); // lowest bit is 1

    // Mask with higher lowest bit: 0x001ffff0
    const xid2 = XID.init(0x04000000, 0x001ffff0);
    try testing.expectEqual(@as(u32, 16), xid2.inc); // lowest bit is 0x10 = 16
}

test "XID genID produces sequential IDs" {
    const testing = std.testing;

    var xid = XID.init(0x04000000, 0x001fffff);

    // First ID should be base | inc
    const id1 = try xid.genID();
    try testing.expectEqual(@as(u32, 0x04000001), id1);

    // Second ID increments
    const id2 = try xid.genID();
    try testing.expectEqual(@as(u32, 0x04000002), id2);

    // Third ID increments
    const id3 = try xid.genID();
    try testing.expectEqual(@as(u32, 0x04000003), id3);
}

test "XID genID with larger increment" {
    const testing = std.testing;

    // Mask 0x10 means increment by 16
    var xid = XID.init(0x100, 0xf0);
    try testing.expectEqual(@as(u32, 16), xid.inc);

    const id1 = try xid.genID();
    try testing.expectEqual(@as(u32, 0x110), id1); // 0x100 | 0x10

    const id2 = try xid.genID();
    try testing.expectEqual(@as(u32, 0x120), id2); // 0x100 | 0x20
}

test "XID genID returns error when exhausted" {
    const testing = std.testing;

    // Small mask: only 3 IDs possible (0x1, 0x2, 0x3)
    var xid = XID.init(0x100, 0x3);
    try testing.expectEqual(@as(u32, 1), xid.inc);

    _ = try xid.genID(); // 0x101
    _ = try xid.genID(); // 0x102
    _ = try xid.genID(); // 0x103, now last == max

    // Next call should error
    try testing.expectError(error.NoMoreIDs, xid.genID());
}
