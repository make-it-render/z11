//! X11 client library.

/// Functions to create a connection to X11 server.
pub const connection = @import("x11/connection.zig");

/// After connecting, need to get Setup information.
pub const setup0 = @import("x11/setup.zig");

/// X11 ID generation mechanism.
pub const xid = @import("x11/xid.zig");

/// All requests, messages, replies and other structs for X11 protocol.
pub const proto = @import("x11/proto.zig");

/// Functions to receive and send data to X11.
pub const io = @import("x11/io.zig");

/// Create and convert images to X11 expected format.
pub const image = @import("x11/image.zig");

/// Random utilities.
pub const utils = @import("x11/utils.zig");

pub const ConnectionOptions = connection.ConnectionOptions;
pub const connect = connection.connect;

pub const setup = setup0.setup;
pub const Setup = setup0.Setup;
pub const Screen = setup0.Screen;
pub const Depth = setup0.Depth;

pub const XID = xid.XID;

pub const send = io.send;
pub const write = io.write;
pub const stream = io.stream;
pub const sendWithBytes = io.sendWithBytes;
pub const sendFromReader = io.sendFromReader;
pub const receive = io.receive;
pub const Message = io.Message;

pub const ImageInfo = image.ImageInfo;
pub const getImageInfo = image.getImageInfo;
pub const rgbaToZPixmapInPlace = image.rgbaToZPixmapInPlace;
pub const rgbaToZPixmapAlloc = image.rgbaToZPixmapAlloc;
pub const RgbaToZPixmapReader = image.RgbaToZPixmapReader;

pub const mask = utils.mask;
pub const maskFromValues = utils.maskFromValues;
pub const sendWithValues = utils.sendWithValues;
pub const internAtom = utils.internAtom;
pub const clientMessageData = utils.clientMessageData;
pub const ClientMessageData = utils.ClientMessageData;
pub const receiveReply = utils.receiveReply;

test {
    _ = connection;
    _ = setup0;
    _ = xid;
    _ = proto;
    _ = io;
    _ = image;
    _ = utils;
}
