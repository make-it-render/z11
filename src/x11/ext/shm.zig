//! MIT-SHM: hand the server pixels through shared memory instead of the socket.
//!
//! Core PutImage writes every pixel of every frame through the connection — ~8 MB per frame for a
//! 1920x1080 window at 32bpp. A segment is mapped once and written in place; presenting it is a
//! 40-byte PutImage that names the segment. The pixels never touch the socket again.
//!
//! Every request here starts with `major_opcode`, which the server assigns per-connection: fill it
//! from `extension.queryExtension(io, conn, "MIT-SHM")` before sending anything.
//!
//! Only the fd-passing transport (AttachFd, minor version 1.2 and up) is implemented. The older
//! SysV path (Attach + shmget) would need four raw syscalls Zig does not wrap, and leaks segments
//! into a global namespace if a client dies before IPC_RMID.

const std = @import("std");
const proto = @import("../proto.zig");
const io = @import("../io.zig");
const utils = @import("../utils.zig");
const xid = @import("../xid.zig");
const extension = @import("../extension.zig");

const testing = std.testing;
const linux = std.os.linux;

const log = std.log.scoped(.x11);

pub const Error = error{
    /// ftruncate failed with EBADF or EINVAL.
    FileTooBig,
    /// A generic I/O error from ftruncate.
    InputOutput,
    /// No space left on device.
    NoSpaceLeft,
    /// Permission denied during ftruncate.
    PermissionDenied,
    /// An unexpected POSIX errno was returned.
    UnexpectedError,
};

/// The name to hand queryExtension.
pub const extension_name = "MIT-SHM";

/// Minor version that introduced AttachFd. Below this, only the SysV transport exists.
pub const fd_passing_minor_version = 2;

/// This extension's own event numbers, added to Extension.first_event.
pub const Event = struct {
    pub const completion = 0;
};

/// This extension's own minor opcodes.
pub const Opcode = struct {
    pub const query_version = 0;
    pub const attach = 1;
    pub const detach = 2;
    pub const put_image = 3;
    pub const get_image = 4;
    pub const create_pixmap = 5;
    pub const attach_fd = 6;
    pub const create_segment = 7;
};

pub const QueryVersion = extern struct {
    major_opcode: u8,
    minor_opcode: u8 = Opcode.query_version,
    length: u16 = @sizeOf(@This()) / 4,
};

pub const QueryVersionReply = extern struct {
    reply: u8,
    /// Whether the server supports CreatePixmap (shared pixmaps).
    shared_pixmaps: u8,
    sequence_number: u16,
    reply_length: u32,
    major_version: u16,
    /// >= fd_passing_minor_version means AttachFd is available.
    minor_version: u16,
    uid: u16,
    gid: u16,
    /// ImageFormat the server uses for shared pixmaps.
    pixmap_format: u8,
    unused: [15]u8,
};

/// Hand the server a file descriptor backing a shared buffer. The fd itself rides out-of-band in
/// an SCM_RIGHTS control message, so this must go through io.sendWithFd rather than io.send.
pub const AttachFd = extern struct {
    major_opcode: u8,
    minor_opcode: u8 = Opcode.attach_fd,
    length: u16 = @sizeOf(@This()) / 4,
    shmseg: u32,
    read_only: u8 = 0,
    unused: [3]u8 = .{ 0, 0, 0 },
};

pub const Detach = extern struct {
    major_opcode: u8,
    minor_opcode: u8 = Opcode.detach,
    length: u16 = @sizeOf(@This()) / 4,
    shmseg: u32,
};

/// The drop-in for core proto.PutImage: identical semantics, but the pixels are read from
/// `offset` into an attached segment instead of trailing the request.
///
/// Set `send_event` to receive a Completion once the server has finished reading, which is the
/// only way to know the segment is safe to overwrite.
pub const PutImage = extern struct {
    major_opcode: u8,
    minor_opcode: u8 = Opcode.put_image,
    length: u16 = @sizeOf(@This()) / 4,
    drawable_id: u32,
    graphic_context_id: u32,
    /// Dimensions of the image as it sits in the segment.
    total_width: u16,
    total_height: u16,
    /// The sub-rectangle of that image to present.
    src_x: u16 = 0,
    src_y: u16 = 0,
    src_width: u16,
    src_height: u16,
    /// Where it lands on the drawable.
    dst_x: i16 = 0,
    dst_y: i16 = 0,
    depth: u8,
    format: proto.ImageFormat = .ZPixmap,
    send_event: u8 = 1,
    unused: u8 = 0,
    shmseg: u32,
    offset: u32 = 0,
};

/// Sent by the server once it has finished reading a segment for a `send_event` PutImage.
/// Arrives on the normal message stream with a runtime code, so it surfaces as io.Message.Generic;
/// match `code` against `Extension.first_event + Event.completion`.
pub const Completion = extern struct {
    code: u8,
    unused: u8,
    sequence_number: u16,
    /// Opcode.put_image.
    minor_event: u16,
    /// The extension's major opcode.
    major_event: u8,
    unused2: u8,
    drawable: u32,
    /// The segment that is now safe to overwrite.
    shmseg: u32,
    offset: u32,
    unused3: [12]u8,
};

// The server reads these off the wire by size; a wrong one is a desync, not a type error.
comptime {
    std.debug.assert(@sizeOf(QueryVersion) == 4);
    std.debug.assert(@sizeOf(QueryVersionReply) == 32);
    std.debug.assert(@sizeOf(AttachFd) == 12);
    std.debug.assert(@sizeOf(Detach) == 8);
    std.debug.assert(@sizeOf(PutImage) == 40);
    std.debug.assert(@sizeOf(Completion) == 32);
}

/// Negotiate MIT-SHM and confirm the server is new enough to accept file descriptors.
/// Returns null when SHM is unavailable — callers must treat that as "use core PutImage",
/// never as an error. Naive reply read: call during init, before an event loop starts.
pub fn probe(io_inst: std.Io, conn: std.Io.net.Stream) (io.Error || utils.Error || extension.Error)!?extension.Extension {
    const ext = try extension.queryExtension(io_inst, conn, extension_name);
    if (!ext.present) {
        log.debug("MIT-SHM not present; falling back to core PutImage", .{});
        return null;
    }

    try io.send(io_inst, conn, QueryVersion{ .major_opcode = ext.major_opcode });
    const reply = try utils.receiveReply(io_inst, conn, QueryVersionReply) orelse return null;

    if (reply.major_version < 1 or
        (reply.major_version == 1 and reply.minor_version < fd_passing_minor_version))
    {
        log.debug("MIT-SHM {d}.{d} predates AttachFd; falling back to core PutImage", .{
            reply.major_version,
            reply.minor_version,
        });
        return null;
    }

    log.debug("MIT-SHM {d}.{d} ready (shared_pixmaps={d})", .{
        reply.major_version,
        reply.minor_version,
        reply.shared_pixmaps,
    });
    return ext;
}

/// Size the buffer. Zig 0.16 dropped std.posix.ftruncate, so go to the syscall.
fn ftruncate(fd: std.posix.fd_t, length: usize) Error!void {
    switch (std.posix.errno(linux.ftruncate(fd, @intCast(length)))) {
        .SUCCESS => return,
        .INTR => return ftruncate(fd, length),
        .FBIG, .INVAL => return error.FileTooBig,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .PERM => return error.PermissionDenied,
        else => return error.UnexpectedError,
    }
}

/// Zig 0.16 dropped std.posix.close too. Closing cannot fail in a way we could act on.
fn closeFd(fd: std.posix.fd_t) void {
    _ = linux.close(fd);
}

/// A shared-memory buffer the server can read directly.
///
/// Write pixels into `bytes`, then present them with a PutImage naming `shmseg`.
///
/// **Reuse is the caller's problem.** The server reads the segment asynchronously, so overwriting
/// `bytes` while it is still copying tears the frame. Send PutImage with `send_event` set and wait
/// for that segment's Completion before touching `bytes` again. How to track that is deliberately
/// left open: it depends on which task reads the connection relative to which one draws, and that
/// is a decision this library should not make for its callers.
pub const Segment = struct {
    /// XID naming this segment in PutImage/Detach.
    shmseg: u32,
    fd: std.posix.fd_t,
    /// The mapping. Write pixels here.
    bytes: []align(std.heap.page_size_min) u8,

    /// Create a shared buffer of `size` bytes and attach it to the server.
    ///
    /// Ordering: the attach goes straight to the socket (the fd needs sendmsg), so it overtakes
    /// anything still buffered for this connection. Flush that writer before calling.
    pub fn init(
        io_inst: std.Io,
        conn: std.Io.net.Stream,
        ext: extension.Extension,
        xids: *xid.XID,
        size: usize,
    ) (io.Error || xid.Error || std.posix.MMapError || std.posix.MemFdCreateError || Error)!Segment {
        std.debug.assert(ext.present);
        _ = io_inst;

        const fd = try std.posix.memfd_create("z11-shm", linux.MFD.CLOEXEC);
        errdefer closeFd(fd);
        try ftruncate(fd, size);

        const bytes = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(bytes);

        const shmseg = try xids.genID();
        try io.sendWithFd(conn, AttachFd{
            .major_opcode = ext.major_opcode,
            .shmseg = shmseg,
        }, fd);

        return .{ .shmseg = shmseg, .fd = fd, .bytes = bytes };
    }

    /// Detach from the server and release the buffer. The XID is not recycled — z11's generator
    /// does not track frees — so churning segments burns IDs.
    pub fn deinit(self: *Segment, io_inst: std.Io, conn: std.Io.net.Stream, ext: extension.Extension) void {
        // Detach first: it tells the server to drop its mapping while ours is still alive.
        io.send(io_inst, conn, Detach{
            .major_opcode = ext.major_opcode,
            .shmseg = self.shmseg,
        }) catch |err| log.err("Failed to detach shm segment: {any}", .{err});

        std.posix.munmap(self.bytes);
        closeFd(self.fd);
    }
};

test "request sizes match the wire format" {
    // Lengths are in 4-byte words and are what the server uses to frame the next request.
    try testing.expectEqual(@as(u16, 1), (QueryVersion{ .major_opcode = 130 }).length);
    try testing.expectEqual(@as(u16, 3), (AttachFd{ .major_opcode = 130, .shmseg = 1 }).length);
    try testing.expectEqual(@as(u16, 2), (Detach{ .major_opcode = 130, .shmseg = 1 }).length);
    try testing.expectEqual(@as(u16, 10), (PutImage{
        .major_opcode = 130,
        .drawable_id = 1,
        .graphic_context_id = 2,
        .total_width = 8,
        .total_height = 8,
        .src_width = 8,
        .src_height = 8,
        .depth = 24,
        .shmseg = 3,
    }).length);
}

test "PutImage lays out where the server expects" {
    const request = PutImage{
        .major_opcode = 130,
        .drawable_id = 0x11223344,
        .graphic_context_id = 0x55667788,
        .total_width = 640,
        .total_height = 480,
        .src_width = 640,
        .src_height = 480,
        .dst_x = -5,
        .dst_y = 7,
        .depth = 24,
        .shmseg = 0x99AABBCC,
        .offset = 0,
    };
    const bytes = std.mem.toBytes(request);

    try testing.expectEqual(@as(u8, 130), bytes[0]);
    try testing.expectEqual(@as(u8, Opcode.put_image), bytes[1]);
    // shmseg and offset are the last two words of the 40-byte request.
    try testing.expectEqual(@as(u32, 0x99AABBCC), std.mem.bytesToValue(u32, bytes[32..36]));
    try testing.expectEqual(@as(u32, 0), std.mem.bytesToValue(u32, bytes[36..40]));
    // Completion is opt-in but on by default: reuse without it is a data race with the server.
    try testing.expectEqual(@as(u8, 1), request.send_event);
    try testing.expectEqual(proto.ImageFormat.ZPixmap, request.format);
}

test "Completion decodes from a raw generic event" {
    // What the reader task actually gets: 32 bytes with a runtime code.
    const first_event: u8 = 65;
    var bytes = [_]u8{0} ** 32;
    bytes[0] = first_event + Event.completion;
    std.mem.writeInt(u16, bytes[4..6], Opcode.put_image, .little);
    bytes[6] = 130; // major_event
    std.mem.writeInt(u32, bytes[8..12], 0x11223344, .little); // drawable
    std.mem.writeInt(u32, bytes[12..16], 0x99AABBCC, .little); // shmseg
    std.mem.writeInt(u32, bytes[16..20], 4096, .little); // offset

    const generic = std.mem.bytesToValue(io.GenericEvent, &bytes);
    const completion = generic.as(Completion);

    try testing.expectEqual(first_event, completion.code);
    try testing.expectEqual(@as(u16, Opcode.put_image), completion.minor_event);
    try testing.expectEqual(@as(u8, 130), completion.major_event);
    try testing.expectEqual(@as(u32, 0x99AABBCC), completion.shmseg);
    try testing.expectEqual(@as(u32, 4096), completion.offset);
}

test "AttachFd carries no shmid, unlike the SysV Attach it replaces" {
    const request = AttachFd{ .major_opcode = 130, .shmseg = 0xDEADBEEF };
    const bytes = std.mem.toBytes(request);

    try testing.expectEqual(@as(u8, 130), bytes[0]);
    try testing.expectEqual(@as(u8, Opcode.attach_fd), bytes[1]);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), std.mem.bytesToValue(u32, bytes[4..8]));
    try testing.expectEqual(@as(u8, 0), request.read_only);
}

// Segment.init/deinit and probe need a live X server, so no test calls them and Zig would never
// analyze their bodies — they would compile-rot silently. Force analysis.
test "segment and probe entry points compile" {
    testing.refAllDecls(Segment);
    _ = &probe;
    _ = &ftruncate;
    _ = &closeFd;
}

test "QueryVersionReply decodes a fd-passing capable server" {
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 1; // reply
    bytes[1] = 1; // shared_pixmaps
    std.mem.writeInt(u16, bytes[8..10], 1, .little); // major_version
    std.mem.writeInt(u16, bytes[10..12], 2, .little); // minor_version

    var reader: std.Io.Reader = .fixed(&bytes);
    const reply = try reader.takeStruct(QueryVersionReply, @import("builtin").cpu.arch.endian());

    try testing.expectEqual(@as(u16, 1), reply.major_version);
    try testing.expectEqual(@as(u16, 2), reply.minor_version);
    try testing.expect(reply.minor_version >= fd_passing_minor_version);
    try testing.expectEqual(@as(u8, 1), reply.shared_pixmaps);
}
