//! A small demo of using the library to create a window, set some properties, receive events and paint a little square.

const std = @import("std");
const x11 = @import("x11");

pub fn main() !void {

    // === Setup === //

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    // This will stabilish a connection to X11 server
    const conn = try x11.connect(.{});
    defer conn.close();

    // Setup will return all informationa about displays, colormode, the root window and others
    // This must be the first function called after connecting
    const info = try x11.setup(allocator, conn);
    defer info.deinit();

    // Every "object" we create we need to assign an ID
    // Those IDs follow a standard based on information from setup
    var xID = x11.XID.init(info.resource_id_base, info.resource_id_mask);

    // === Atoms === //

    // Atom are like variables for X11, when we intern an atom we get a reference, and ID for that Atom that is shared with the server
    // WM_PROTOCOLS is used to bridge between your window, x11 and the window manager (like gnome or kde)
    const intern_wm_protocols = x11.proto.InternAtom{ .length_of_name = "WM_PROTOCOLS".len, .only_if_exists = true };

    // This function send a request (in this case: InterAtom) to X11, with some extra bytes
    // It calculates the right length and padding that X11 expects
    // There are other ways to send requests futher below
    try x11.sendWithBytes(conn, intern_wm_protocols, "WM_PROTOCOLS");

    // InternAtom generated a reply, here we read it
    const wm_protocols = try x11.receiveReply(conn, x11.proto.InternAtomReply);
    if (wm_protocols == null) {
        return error.NoWMProtocols;
    }

    // There is a utility function to make it easier to intern atoms
    const string_atom = try x11.internAtom(conn, "STRING");
    const atom_atom = try x11.internAtom(conn, "ATOM");
    const wm_name_atom = try x11.internAtom(conn, "WM_NAME"); // Used for the window title
    const wm_delete_window_atom = try x11.internAtom(conn, "WM_DELETE_WINDOW"); // Used to get notification of window closing

    // === Creating an Window === //

    // To create a window, we first generate an ID for it
    const window_id = try xID.genID();
    // These are the events we want to get notified about
    const event_masks = [_]x11.proto.EventMask{ .Exposure, .StructureNotify, .SubstructureNotify, .PropertyChange };
    // You see we set some information from the Setup return, and the events
    const window_values = x11.proto.WindowValue{
        .BackgroundPixel = info.screens[0].black_pixel,
        .EventMask = x11.mask(&event_masks),
        .Colormap = info.screens[0].colormap,
    };
    const create_window = x11.proto.CreateWindow{
        .window_id = window_id,

        .parent_id = info.screens[0].root,
        .visual_id = info.screens[0].root_visual,
        .depth = info.screens[0].root_depth,

        .x = 10,
        .y = 10,
        .width = 480,
        .height = 240,
        .border_width = 0,
        .window_class = .InputOutput,

        // value mask follow a certain pattern, so there is an util function for that
        .value_mask = x11.maskFromValues(x11.proto.WindowMask, window_values),
    };
    // Here we send the CreateWindow request, with the extra values
    try x11.sendWithValues(conn, create_window, window_values);

    // After creating a Window, we Map it so it appears
    const map_req = x11.proto.MapWindow{ .window_id = window_id };
    // This is how you send a request without extra information
    try x11.send(conn, map_req);

    // === Changing Window Properties === //

    // Changing the title of the window
    const set_name_req = x11.proto.ChangeProperty{
        .window_id = window_id,
        .property = wm_name_atom,
        .property_type = string_atom,
        .length_of_data = 5,
    };
    try x11.sendWithBytes(conn, set_name_req, "hello");

    // Setting the Protocol to receive the window delete notification from window manager
    const set_protocols = x11.proto.ChangeProperty{
        .window_id = window_id,
        .property = wm_protocols.?.atom,
        .property_type = atom_atom,
        .format = 32,
        .length_of_data = 1,
    };
    try x11.sendWithBytes(conn, set_protocols, &std.mem.toBytes(wm_delete_window_atom));

    // === Drawing and graphics === //

    // For drawing we need a graphics context
    // It holds information about HOW things are rendered
    // You can have different GCs (graphic context) for different render types
    const graphic_context_id = try xID.genID();
    const graphic_context_values = x11.proto.GraphicContextValue{
        .Background = info.screens[0].black_pixel,
        .Foreground = info.screens[0].white_pixel,
    };
    const create_gc = x11.proto.CreateGraphicContext{
        .graphic_context_id = graphic_context_id,
        .drawable_id = window_id,
        .value_mask = x11.maskFromValues(x11.proto.GraphicContextMask, graphic_context_values),
    };
    try x11.sendWithValues(conn, create_gc, graphic_context_values);

    // We draw in a pixmap
    // This is where the pixels go
    const pixmap_id = try xID.genID();
    const pixmap_req = x11.proto.CreatePixmap{
        .pixmap_id = pixmap_id,
        .drawable_id = window_id,
        .width = 5,
        .height = 5,
        .depth = create_window.depth,
    };
    try x11.send(conn, pixmap_req);

    // Let's make a little yellow triangle
    const y = [4]u8{ 255, 150, 0, 1 };
    const b = [4]u8{ 0, 0, 0, 0 };
    const yellow_block: [5 * 5][4]u8 = [_][4]u8{
        b, b, y, b, b,
        b, y, y, y, b,
        b, y, y, y, b,
        y, y, y, y, y,
        y, y, y, y, y,
    };
    const pixels = std.mem.toBytes(yellow_block);

    // X11 does not work with RGB(a) as describe above, instead that are more information and formats needed
    // This function return some information to make it posible to convert to X11 expected format
    const imageInfo = x11.getImageInfo(info, create_window.parent_id);

    // Here we will convert to a format called ZPixmap
    //const yellow_block_zpixmap = try x11.rgbaToZPixmapAlloc(allocator, imageInfo, &pixels);
    //defer allocator.free(yellow_block_zpixmap);
    // try x11.rgbaToZPixmapInPlace(imageInfo, pixels);

    // let's try the Reader/Writer version
    var pixels_reader = std.Io.Reader.fixed(&pixels);
    var pixmap_reader = x11.RgbaToZPixmapReader.init(imageInfo, &pixels_reader);

    // Now that we how our pixels on the expected format
    // We put the pixels on the pixmap, using the graphic context
    // It is important to fill the whole pixmap
    // and ideally only use a pixmap of the size you intend to draw
    // Non used parts of pixmap may contain any data
    const put_image_req = x11.proto.PutImage{
        .drawable_id = pixmap_id,
        .graphic_context_id = graphic_context_id,
        .width = 5,
        .height = 5,
        .x = 0,
        .y = 0,
        .depth = pixmap_req.depth,
    };
    //try x11.sendWithBytes(conn, put_image_req, yellow_block_zpixmap);

    var net_writer_buffer: [64]u8 = undefined;
    var net_writer = conn.writer(&net_writer_buffer);
    var writer = &net_writer.interface;
    try x11.stream(writer, put_image_req, (&pixmap_reader).interface(), pixels.len);
    try writer.flush();

    // === Main loop === //

    var timer = try std.time.Timer.start();

    // Now we have the main loop
    // Here we receive events and send draw requests
    var open = true;
    while (open) {
        while (try x11.receive(conn)) |message| {
            switch (message) {
                .Expose => {
                    timer.reset();
                    // Expose means we need to draw to the window
                    // It also include the area we need to draw to

                    // First we can clear the whole window, but it is not mandatory
                    // But you can also just clear the needed area
                    const clear_area = x11.proto.ClearArea{
                        .window_id = window_id,
                    };
                    try x11.send(conn, clear_area);

                    // Than we copy our pixmap to our window
                    // again using the graphic context
                    // This will finally draw something visible
                    const copy_area_req = x11.proto.CopyArea{
                        .src_drawable_id = pixmap_id,
                        .dst_drawable_id = window_id,
                        .graphic_context_id = graphic_context_id,
                        .width = pixmap_req.width,
                        .height = pixmap_req.height,
                        .dst_x = 100,
                        .dst_y = 200,
                    };
                    try x11.send(conn, copy_area_req);

                    log.debug("Time to draw: {d}ms", .{timer.lap() / std.time.ns_per_ms});
                },
                .ClientMessage => |client_message| {
                    // ClientMessage is how other X11 clients communicate
                    // In this case it is used to receive the notification that we should close the window
                    const client_message_data = x11.clientMessageData(client_message);
                    if (client_message_data.u32[0] == wm_delete_window_atom) {
                        open = false;
                    }
                },
                else => {},
            }
        }
    }

    // When done, we can release all resources.
    try x11.send(conn, x11.proto.FreeGraphicContext{ .graphic_context_id = graphic_context_id });
    try x11.send(conn, x11.proto.FreePixmap{ .pixmap_id = pixmap_id });
    try x11.send(conn, x11.proto.UnmapWindow{ .window_id = window_id });
    try x11.send(conn, x11.proto.DestroyWindow{ .window_id = window_id });
}

const log = std.log.scoped(.demo);

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .x11, .level = .warn },
        .{ .scope = .demo, .level = .debug },
    },
};
