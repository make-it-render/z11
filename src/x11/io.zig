//! Functions to send Requests and receive Responses, Messages and Replies from an X11 socket.
//! This will be part of your core loop.

pub const Error = error{
    /// A send/recv syscall was interrupted by a signal and would block.
    WouldBlock,
    /// The peer closed the connection.
    ConnectionClosed,
    /// The system is out of resources (memory, file descriptors).
    SystemResources,
    /// A write to the socket failed.
    WriteFailed,
    /// A read from the socket failed.
    ReadFailed,
    /// Parsing a message or reply failed (e.g. truncated struct).
    ParseFailed,
    /// The reader hit EOF before expected data.
    EndOfStream,
    /// An unexpected POSIX errno was returned from a syscall.
    UnexpectedError,
    /// `sendWithFd` wrote fewer bytes than the request size — desync risk.
    SendWithFdTruncated,
};

/// Send a request to a socket.
/// Use with any Request struct from proto namespace that does not need extra data.
pub fn send(io: std.Io, conn: std.Io.net.Stream, request: anytype) Error!void {
    var buffer: [256]u8 = undefined;
    var net_writer = conn.writer(io, &buffer);
    const writer = &net_writer.interface;
    try write(writer, request);
    try writer.flush();
}

/// Send a request to a socket with some extra bytes at the end.
/// It re-calculate the apropriate length and add needed padding.
/// Use with Request structs from proto namespace that require additional data to be sent.
pub fn sendWithBytes(io: std.Io, conn: std.Io.net.Stream, request: anytype, extra_bytes: []const u8) Error!void {
    const req_bytes = request_bytes_fixed_len(request, extra_bytes.len);
    //log.debug("Sending (size: {d}): {any}", .{ req_bytes.len, request });

    const pad_len = get_pad_len(extra_bytes.len);
    const padding: [3]u8 = .{ 0, 0, 0 };
    const pad = padding[0..pad_len];

    var buffer: [256]u8 = undefined;
    var net_writer = conn.writer(io, &buffer);
    const writer = &net_writer.interface;
    try writer.writeAll(&req_bytes);
    try writer.writeAll(extra_bytes);
    try writer.writeAll(pad);
    try writer.flush();
}

/// Send a request that carries a file descriptor to the server, as MIT-SHM's AttachFd needs.
///
/// The fd travels out-of-band in an SCM_RIGHTS control message rather than in the request body,
/// so this cannot go through a std.Io.Writer and has to reach for sendmsg directly. Zig 0.16 has
/// no std.posix.sendmsg and no CMSG_* helpers, so the control message is laid out by hand below.
///
/// Two things the caller owns:
///   - **Ordering.** This writes straight to the socket, so it overtakes anything still sitting in
///     a buffered writer over the same connection. Flush that writer first.
///   - **The fd.** sendmsg duplicates it into the server; our copy is still ours to close.
///
/// The write is a raw blocking syscall, not an `io` cancelation point. That is fine for the tiny,
/// init-time requests this is meant for, and the reason it takes no `std.Io`.
pub fn sendWithFd(conn: std.Io.net.Stream, request: anytype, fd: std.posix.fd_t) Error!void {
    const req_bytes = std.mem.toBytes(request);
    var iov = [_]std.posix.iovec_const{.{ .base = &req_bytes, .len = req_bytes.len }};

    var control: [cmsgSpace(@sizeOf(std.posix.fd_t))]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const header: *linux.cmsghdr = @ptrCast(&control);
    header.* = .{
        .len = cmsgLen(@sizeOf(std.posix.fd_t)),
        .level = std.posix.SOL.SOCKET,
        .type = linux.SCM.RIGHTS,
    };
    @memcpy(control[cmsgDataOffset()..][0..@sizeOf(std.posix.fd_t)], std.mem.asBytes(&fd));

    const message = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };

    while (true) {
        const rc = linux.sendmsg(conn.socket.handle, &message, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                // A short send would desync the request stream with no way to resend the fd, so
                // refuse rather than corrupt it. These requests are a few bytes; it does not happen.
                if (rc != req_bytes.len) return error.SendWithFdTruncated;
                return;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE, .CONNRESET => return error.ConnectionClosed,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.UnexpectedError,
        }
    }
}

/// Byte offset of a control message's payload: the header rounded up to its alignment.
/// Mirrors the kernel's CMSG_DATA.
fn cmsgDataOffset() usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr));
}

/// Round up to the kernel's control-message alignment. Mirrors CMSG_ALIGN.
fn cmsgAlign(len: usize) usize {
    return (len + @sizeOf(usize) - 1) & ~(@as(usize, @sizeOf(usize)) - 1);
}

/// Value for cmsghdr.len: header plus payload, payload unpadded. Mirrors CMSG_LEN.
fn cmsgLen(payload_len: usize) usize {
    return cmsgDataOffset() + payload_len;
}

/// Buffer size needed to hold one control message, payload padded. Mirrors CMSG_SPACE.
fn cmsgSpace(payload_len: usize) usize {
    return cmsgDataOffset() + cmsgAlign(payload_len);
}

/// Write a request into a writer (no flush; the caller controls when to flush).
/// Use with any Request struct from proto namespace that does not need extra data.
pub fn write(writer: *std.Io.Writer, request: anytype) Error!void {
    const req_bytes: []const u8 = &std.mem.toBytes(request);
    //log.debug("Sending (size: {d}): {any}", .{ req_bytes.len, request });
    try writer.writeAll(req_bytes);
}

/// Write a request to a writer with some extra bytes at the end from a reader.
/// It re-calculate the apropriate length and add needed padding.
/// Use with Request structs from proto namespace that require additional data to be sent.
pub fn stream(writer: *std.Io.Writer, request: anytype, reader: *std.Io.Reader, extra_len: usize) Error!void {
    const req_bytes = request_bytes_fixed_len(request, extra_len);

    // calculate padding and send it
    const pad_len = get_pad_len(extra_len);
    const padding: [3]u8 = .{ 0, 0, 0 };
    const pad = padding[0..pad_len];

    try writer.writeAll(&req_bytes);
    const written = try reader.stream(writer, std.Io.Limit.limited(extra_len));
    std.debug.assert(written == extra_len);
    try writer.writeAll(pad);
}

/// Return the request as a byte slice, with length property fixed to consider extra bytes and padding.
fn request_bytes_fixed_len(request: anytype, bytes_len: usize) [@sizeOf(@TypeOf(request))]u8 {
    var req_bytes = std.mem.toBytes(request);

    // re-calc length to include extra data

    // get length including the request, extra bytes and padding needed
    const length = get_padded_len(request, bytes_len);
    // bytes 3 and 4 (a u16) of a request is always length, we can override it to include the total size
    const len_bytes = std.mem.toBytes(length);
    req_bytes[2] = len_bytes[0];
    req_bytes[3] = len_bytes[1];

    //log.debug("Sending (size: {d}): {any}", .{ req_bytes.len, request });
    //log.debug("Sending extra bytes len  {d}", .{bytes_len});

    return req_bytes;
}

/// Return total length, including padding, that is need for whole data to be a multiple of 4.
fn get_padded_len(request: anytype, src_bytes_len: usize) u16 {
    const req_len: usize = @sizeOf(@TypeOf(request)) / 4;
    const pad_len: usize = get_pad_len(src_bytes_len);
    const extra_len: usize = (src_bytes_len + pad_len) / 4;
    return @intCast(req_len + extra_len);
}

test "Length calc" {
    const change_prop = proto.ChangeProperty{ .window_id = 0, .property = 0, .property_type = 0 };
    const len0 = get_padded_len(change_prop, "".len);

    try testing.expectEqual(6, len0);

    const len1 = get_padded_len(change_prop, "hello".len);
    try testing.expectEqual(8, len1);
}

/// Get how much padding is needed for the extra bytes to be multiple of 4.
fn get_pad_len(bytes_len: usize) usize {
    const missing = bytes_len % 4;
    if (missing == 0) {
        return 0;
    }
    return 4 - missing;
}

test "padding length" {
    const len0 = get_pad_len("".len);
    try testing.expectEqual(0, len0);

    const len1 = get_pad_len("1234".len);
    try testing.expectEqual(0, len1);

    const len2 = get_pad_len("12345".len);
    try testing.expectEqual(3, len2);

    const len3 = get_pad_len("12345678".len);
    try testing.expectEqual(0, len3);
}

/// Receive a single X11 message (exactly 32 bytes) from a socket.
///
/// The `timeout` controls how long to wait for a message to start arriving:
/// - `.none` blocks until a message arrives. The wait happens on a std.Io worker,
///   so an idle caller uses no CPU (no busy-poll). Use this for event-driven loops
///   and thread-per-source readers.
/// - `.{ .duration = ... }` (or `.deadline`) returns `null` once it elapses with no
///   message pending, so callers can poll, e.g. to render a frame on a fixed cadence.
pub fn receive(io: std.Io, conn: std.Io.net.Stream, timeout: std.Io.Timeout) Error!?Message {
    var message_buffer: [32]u8 = undefined;

    switch (timeout) {
        // Block until the whole message arrives (on a std.Io worker, so idle = no CPU).
        .none => try receiveBytes(io, conn, &message_buffer),
        // Wait up to `timeout` for the first bytes; report "no message" if it elapses.
        else => {
            const message = conn.socket.receiveTimeout(io, &message_buffer, timeout) catch {
                return error.ReadFailed;
            };
            if (message.data.len == 0) return error.ConnectionClosed; // peer closed
            // The first read may be partial; block for the rest of the 32-byte message.
            if (message.data.len < message_buffer.len) {
                try receiveBytes(io, conn, message_buffer[message.data.len..]);
            }
        },
    }

    return parseMessage(message_buffer);
}

/// Read exactly `buffer.len` bytes from the connection, blocking until they all arrive.
///
/// This is the single primitive every socket read goes through. It uses recvmsg, which
/// only ever consumes what we ask for (the kernel keeps the rest), so there is no
/// read-ahead buffer that could strand bytes between successive reads — replies and
/// their trailing data stay perfectly aligned without sharing a stateful reader.
pub fn receiveBytes(io: std.Io, conn: std.Io.net.Stream, buffer: []u8) Error!void {
    var received: usize = 0;
    while (received < buffer.len) {
        const message = conn.socket.receive(io, buffer[received..]) catch {
            return error.ReadFailed;
        };
        if (message.data.len == 0) return error.ConnectionClosed; // peer closed mid-read
        received += message.data.len;
    }
}

/// Decode a raw 32-byte X11 message into a Message union value.
fn parseMessage(message_buffer: [32]u8) Error!?Message {
    var message_reader: std.Io.Reader = .fixed(&message_buffer);

    // The most significant bit in this code is set if the event was generated from a SendEvent
    // So we remove it
    const message_code = message_buffer[0] & 0b01111111;
    const sent_event = message_buffer[0] & 0b10000000 == 0b10000000;

    // Using comptime to map to all known messages
    const message_tag = std.meta.Tag(Message); // Get Tag object of list of possible messages
    const message_values = comptime std.meta.fields(message_tag); // Get all fields of the Tag
    inline for (message_values) |tag| { // For each possible message
        // Generic is not a wire code, it is the fallback below. Skipping it at comptime also
        // keeps @field(proto, ...) from being analyzed for a name proto does not define.
        if (comptime !std.mem.eql(u8, tag.name, "Generic")) {
            // Here is emitted code
            if (message_code == tag.value) { // The tag value is the same as the received message
                // Return the struct from the bytes and build the union.
                const message = try message_reader.takeStruct(@field(proto, tag.name), endian);
                //log.debug("Received message ({any}): {any}", .{ sent_event, message });
                return @unionInit(Message, tag.name, message);
            }
        }
    }

    // Extension events carry codes assigned at runtime (first_event), so they can never have a
    // static variant. Hand the raw bytes back and let the caller match the code against the
    // first_event of whichever extension it negotiated.
    log.debug("Generic message: code={d} sent={any}", .{ message_code, sent_event });

    var generic = std.mem.bytesToValue(GenericEvent, &message_buffer);
    generic.code = message_code; // masked, so callers compare against first_event directly
    return .{ .Generic = generic };
}

/// A Map with all known messages, in order of message code.
pub const Message = union(enum(u8)) {
    ErrorMessage: proto.ErrorMessage,
    /// A reply (code 1) read where an event was expected. It answers whatever request the
    /// caller last sent with a reply; see `proto.Reply.extraLength` for what to drain.
    Reply: proto.Reply,
    KeyPress: proto.KeyPress,
    KeyRelease: proto.KeyRelease,
    ButtonPress: proto.ButtonPress,
    ButtonRelease: proto.ButtonRelease,
    MotionNotify: proto.MotionNotify,
    EnterNotify: proto.EnterNotify,
    LeaveNotify: proto.LeaveNotify,
    FocusIn: proto.FocusIn,
    FocusOut: proto.FocusOut,
    KeymapNotify: proto.KeymapNotify,
    Expose: proto.Expose,
    GraphicsExposure: proto.GraphicsExposure,
    NoExposure: proto.NoExposure,
    VisibilityNotify: proto.VisibilityNotify,
    CreateNotify: proto.CreateNotify,
    DestroyNotify: proto.DestroyNotify,
    UnmapNotify: proto.UnmapNotify,
    MapNotify: proto.MapNotify,
    MapRequest: proto.MapRequest,
    ReparentNotify: proto.ReparentNotify,
    ConfigureNotify: proto.ConfigureNotify,
    ConfigureRequest: proto.ConfigureRequest,
    GravityNotify: proto.GravityNotify,
    ResizeRequest: proto.ResizeRequest,
    CirculateNotify: proto.CirculateNotify,
    CirculateRequest: proto.CirculateRequest,
    PropertyNotify: proto.PropertyNotify,
    SelectionClear: proto.SelectionClear,
    SelectionRequest: proto.SelectionRequest,
    SelectionNotify: proto.SelectionNotify,
    ColormapNotify: proto.ColormapNotify,
    ClientMessage: proto.ClientMessage,
    MappingNotify: proto.MappingNotify,
    /// Any code with no static variant above — extension events, and core codes we do not model.
    /// Pinned to 255 so it stays clear of the 0..127 range a real event code can occupy.
    Generic: GenericEvent = 255,
};

/// An undecoded 32-byte message. `code` already has the SendEvent bit masked off.
pub const GenericEvent = extern struct {
    code: u8,
    bytes: [31]u8,

    /// Reinterpret the raw bytes as a concrete extension event struct, e.g. shm.Completion.
    /// Only valid once `code` has been matched against that extension's first_event.
    pub fn as(self: *const @This(), EventType: type) EventType {
        comptime std.debug.assert(@sizeOf(EventType) == 32);
        return std.mem.bytesToValue(EventType, std.mem.asBytes(self));
    }
};

test "parseMessage decodes a known core event" {
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 12; // Expose

    const message = (try parseMessage(bytes)).?;
    try testing.expect(message == .Expose);
}

test "parseMessage decodes the selection events" {
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 30; // SelectionRequest
    std.mem.writeInt(u32, bytes[12..16], 0x400001, endian); // requestor
    std.mem.writeInt(u32, bytes[20..24], 0x1F0, endian); // target

    const request = (try parseMessage(bytes)).?;
    try testing.expect(request == .SelectionRequest);
    try testing.expectEqual(@as(u32, 0x400001), request.SelectionRequest.requestor);
    try testing.expectEqual(@as(u32, 0x1F0), request.SelectionRequest.target);

    bytes[0] = 29;
    try testing.expect((try parseMessage(bytes)).? == .SelectionClear);
    bytes[0] = 31;
    try testing.expect((try parseMessage(bytes)).? == .SelectionNotify);
}

test "parseMessage hands a reply back with its trailing length" {
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 1;
    std.mem.writeInt(u32, bytes[4..8], 5, endian);

    const message = (try parseMessage(bytes)).?;
    try testing.expect(message == .Reply);
    try testing.expectEqual(@as(usize, 20), message.Reply.extraLength());
}

test "parseMessage returns Generic for an extension event code" {
    // 65 is a plausible MIT-SHM first_event. No static variant covers it.
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 65;
    bytes[4] = 3; // minor_event, i.e. ShmPutImage
    bytes[31] = 0xAB;

    const message = (try parseMessage(bytes)).?;
    try testing.expect(message == .Generic);
    try testing.expectEqual(@as(u8, 65), message.Generic.code);
    // The payload survives intact for the caller to reinterpret.
    try testing.expectEqual(@as(u8, 3), message.Generic.bytes[3]);
    try testing.expectEqual(@as(u8, 0xAB), message.Generic.bytes[30]);
}

test "parseMessage masks the SendEvent bit off a Generic code" {
    // A SendEvent-generated extension event still has to match first_event.
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 65 | 0b10000000;

    const message = (try parseMessage(bytes)).?;
    try testing.expectEqual(@as(u8, 65), message.Generic.code);
}

test "Generic tag value cannot collide with a wire event code" {
    // Wire codes are 0..127 after masking; Generic is pinned above that.
    const tag = @intFromEnum(std.meta.Tag(Message).Generic);
    try testing.expectEqual(@as(u8, 255), tag);
    try testing.expect(tag > 127);
}

test "GenericEvent is exactly one X11 message" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(GenericEvent));
}

// The cmsg layout is the one piece here the kernel will reject silently rather than loudly,
// so pin the arithmetic against the values CMSG_* produce for a single fd on a 64-bit target.
test "cmsg alignment rounds up to a pointer word" {
    try testing.expectEqual(@as(usize, 0), cmsgAlign(0));
    try testing.expectEqual(@as(usize, 8), cmsgAlign(1));
    try testing.expectEqual(@as(usize, 8), cmsgAlign(8));
    try testing.expectEqual(@as(usize, 16), cmsgAlign(9));
    try testing.expectEqual(@as(usize, 16), cmsgAlign(16));
}

test "cmsg header layout matches the kernel's" {
    // len(usize) + level(i32) + type(i32), and the payload starts right after it.
    try testing.expectEqual(@as(usize, 16), @sizeOf(linux.cmsghdr));
    try testing.expectEqual(@as(usize, 16), cmsgDataOffset());
}

test "cmsg len and space for a single fd" {
    const fd_size = @sizeOf(std.posix.fd_t);
    try testing.expectEqual(@as(usize, 4), fd_size);

    // CMSG_LEN(4) = 16 + 4: what cmsghdr.len must report to the kernel.
    try testing.expectEqual(@as(usize, 20), cmsgLen(fd_size));
    // CMSG_SPACE(4) = 16 + 8: what the buffer must reserve, payload padded.
    try testing.expectEqual(@as(usize, 24), cmsgSpace(fd_size));
    // Space always leaves room for len; the difference is padding only.
    try testing.expect(cmsgSpace(fd_size) >= cmsgLen(fd_size));
}

test "SCM_RIGHTS is the constant the kernel expects" {
    try testing.expectEqual(@as(i32, 1), linux.SCM.RIGHTS);
}

// The arithmetic tests above only prove we agree with ourselves. This one makes the kernel judge
// the layout: a malformed control message is silently dropped rather than rejected, so the fd
// would just never arrive. Round-tripping a real fd over a socketpair is what actually proves
// sendWithFd works before an X server is ever involved.
test "sendWithFd delivers both the request and the descriptor" {
    var pair: [2]i32 = undefined;
    if (linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);

    // Stand in for a real segment fd: a memfd holding known bytes.
    const payload_fd = try std.posix.memfd_create("z11-shm-test", linux.MFD.CLOEXEC);
    defer _ = linux.close(payload_fd);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(linux.ftruncate(payload_fd, 4)));
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(linux.pwrite(payload_fd, "abcd", 4, 0)));

    const request = proto.QueryExtension{ .length_of_name = 7 };
    const conn = std.Io.net.Stream{ .socket = .{ .handle = pair[0], .address = undefined } };
    try sendWithFd(conn, request, payload_fd);

    // Read the request body back.
    var body: [@sizeOf(proto.QueryExtension)]u8 = undefined;
    var iov = [_]std.posix.iovec{.{ .base = &body, .len = body.len }};
    var control: [cmsgSpace(@sizeOf(std.posix.fd_t))]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var message = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const received = linux.recvmsg(pair[1], &message, 0);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(received));
    try testing.expectEqual(@as(usize, body.len), received);
    try testing.expectEqualSlices(u8, &std.mem.toBytes(request), &body);

    // The kernel filled in a control message of exactly the shape we claimed.
    const header: *const linux.cmsghdr = @ptrCast(&control);
    try testing.expectEqual(@as(i32, std.posix.SOL.SOCKET), header.level);
    try testing.expectEqual(@as(i32, linux.SCM.RIGHTS), header.type);
    try testing.expectEqual(cmsgLen(@sizeOf(std.posix.fd_t)), header.len);

    // The descriptor arrived as a distinct fd onto the same file: proof it really transferred,
    // which is exactly what the X server relies on to map our segment.
    const got_fd = std.mem.bytesToValue(std.posix.fd_t, control[cmsgDataOffset()..][0..@sizeOf(std.posix.fd_t)]);
    defer _ = linux.close(got_fd);
    try testing.expect(got_fd != payload_fd);

    var round_tripped: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), linux.pread(got_fd, &round_tripped, 4, 0));
    try testing.expectEqualSlices(u8, "abcd", &round_tripped);
}

const std = @import("std");
const proto = @import("proto.zig");

const linux = std.os.linux;
const testing = std.testing;
const endian = @import("builtin").cpu.arch.endian();

const log = std.log.scoped(.x11);
