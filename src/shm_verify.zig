//! Proves the MIT-SHM path works against a real X server, end to end.
//!
//! The parts of SHM that unit tests cannot reach are the ones most likely to be wrong: whether the
//! server accepts our SCM_RIGHTS control message, whether it can actually read the memfd we mapped,
//! and whether ShmPutImage lands the pixels where we claimed. So this writes a known pattern into a
//! segment, presents it into a pixmap, reads it back with GetImage and compares.
//!
//! A pixmap rather than a window on purpose: pixmap contents are well defined whether or not
//! anything is mapped or composited, so this is deterministic and needs no visible output.
//!
//! Run with `zig build shm-verify`. Exits non-zero on any mismatch.

const std = @import("std");
const x11 = @import("x11");

const width = 64;
const height = 64;
const bytes_per_pixel = 4;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    const conn = try x11.connect(io, environ, .{});
    defer conn.close(io);

    const info = try x11.setup(io, environ, allocator, conn);
    defer info.deinit();

    var xid = x11.XID.init(info.resource_id_base, info.resource_id_mask);
    const screen = info.screens[0];

    const ext = try x11.shm.probe(io, conn) orelse {
        std.debug.print("FAIL: server has no usable MIT-SHM; nothing to verify\n", .{});
        return error.ShmUnavailable;
    };
    std.debug.print("MIT-SHM negotiated: major_opcode={d} first_event={d} first_error={d}\n", .{
        ext.major_opcode,
        ext.first_event,
        ext.first_error,
    });

    // A pixmap of the root's depth is what the present path draws into.
    const pixmap_id = try xid.genID();
    try x11.send(io, conn, x11.proto.CreatePixmap{
        .pixmap_id = pixmap_id,
        .drawable_id = screen.root,
        .width = width,
        .height = height,
        .depth = screen.root_depth,
    });
    defer x11.send(io, conn, x11.proto.FreePixmap{ .pixmap_id = pixmap_id }) catch {};

    const gc_id = try xid.genID();
    try x11.send(io, conn, x11.proto.CreateGraphicContext{
        .graphic_context_id = gc_id,
        .drawable_id = pixmap_id,
        .value_mask = 0,
    });
    defer x11.send(io, conn, x11.proto.FreeGraphicContext{ .graphic_context_id = gc_id }) catch {};

    // Twice over, detaching in between. One pass proves a segment works; two prove Detach leaves
    // the connection healthy and a fresh segment can take over — which is exactly what a window
    // resize does, and the case where a wrong request would surface as a delayed BadShmSeg.
    for (0..2) |pass| {
        try roundTrip(allocator, io, conn, ext, &xid, pixmap_id, gc_id, screen.root_depth, pass);
    }

    std.debug.print("PASS: pixels survived memfd -> SCM_RIGHTS -> ShmPutImage -> GetImage intact, across a detach\n", .{});
}

/// Attach a segment, present a known pattern through it, read it back, compare, detach.
fn roundTrip(
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: std.Io.net.Stream,
    ext: x11.Extension,
    xid: *x11.XID,
    pixmap_id: u32,
    gc_id: u32,
    depth: u8,
    pass: usize,
) !void {
    // The moment of truth for sendWithFd: if the control message is malformed the server never
    // gets the descriptor, and everything after this fails.
    const size = width * height * bytes_per_pixel;
    var segment = try x11.shm.Segment.init(io, conn, ext, xid, size);
    defer segment.deinit(io, conn, ext);
    std.debug.print("pass {d}: segment attached shmseg={d} fd={d} bytes={d}\n", .{
        pass,
        segment.shmseg,
        segment.fd,
        segment.bytes.len,
    });

    // A gradient, so a wrong stride or a swapped channel shows up as a mismatch rather than
    // happening to match. Varied per pass so the second pass cannot pass on stale pixmap contents.
    // Written as ZPixmap (BGRA) — the format the wire actually carries.
    const expected = try allocator.alloc(u8, size);
    defer allocator.free(expected);
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * bytes_per_pixel;
            expected[offset + 0] = @intCast((y * 4 + pass * 17) % 256); // blue
            expected[offset + 1] = @intCast((x * 4 + pass * 33) % 256); // green
            expected[offset + 2] = @intCast(((x + y) * 2 + pass * 55) % 256); // red
            expected[offset + 3] = 0;
        }
    }
    @memcpy(segment.bytes, expected);

    // send_event = 0 deliberately: a ShmCompletion would arrive ahead of the GetImage reply and
    // the naive reply reader would decode the event as the reply. The GetImage round-trip below
    // is itself the proof the server finished reading.
    try x11.send(io, conn, x11.shm.PutImage{
        .major_opcode = ext.major_opcode,
        .drawable_id = pixmap_id,
        .graphic_context_id = gc_id,
        .total_width = width,
        .total_height = height,
        .src_width = width,
        .src_height = height,
        .depth = depth,
        .shmseg = segment.shmseg,
        .send_event = 0,
    });

    try x11.send(io, conn, x11.proto.GetImage{
        .drawable_id = pixmap_id,
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    });
    const reply = try x11.receiveReply(io, conn, x11.proto.GetImageReply) orelse {
        std.debug.print("FAIL: no GetImage reply\n", .{});
        return error.NoReply;
    };
    // An error message is 32 bytes too, so a server complaint would land here posing as the reply.
    if (reply.reply != 1) {
        std.debug.print("FAIL: expected a reply, got message type {d} (an X error?)\n", .{reply.reply});
        return error.UnexpectedMessage;
    }

    const readback = try allocator.alloc(u8, reply.reply_length * 4);
    defer allocator.free(readback);
    try x11.receiveBytes(io, conn, readback);

    if (readback.len < size) {
        std.debug.print("FAIL: read back {d} bytes, expected at least {d}\n", .{ readback.len, size });
        return error.ShortReadback;
    }

    // The server may zero or ignore the pad byte of each pixel depending on depth, so compare the
    // three colour channels: those are what SHM actually had to transport.
    var mismatches: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * bytes_per_pixel;
            for (0..3) |channel| {
                if (readback[offset + channel] != expected[offset + channel]) mismatches += 1;
            }
        }
    }

    if (mismatches != 0) {
        std.debug.print("FAIL: pass {d}: {d} of {d} colour channels differ after the SHM round trip\n", .{
            pass,
            mismatches,
            width * height * 3,
        });
        return error.PixelMismatch;
    }
    std.debug.print("pass {d}: {d}x{d} pixels verified\n", .{ pass, width, height });
}
