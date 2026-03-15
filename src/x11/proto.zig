//! Structs following X11 protocol.
//! Here we have all messages, requests, responses and replies that can be sent or received from X11 server.
//! Structs are extern so they can be directly serialized/deserialized and have fixed byte format.

// common structs

pub const Point = extern struct {
    x: i16 = 0,
    y: i16 = 0,
};

pub const Rectangle = extern struct {
    x: i16 = 0,
    y: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
};

pub const Arc = extern struct {
    x: i16 = 0,
    y: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    angle1: i16 = 0,
    angle2: i16 = 0,
};

pub const Format = extern struct {
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
    pad: [5]u8,
};

pub const VisualClass = enum(u8) {
    StaticGray = 0,
    GrayScale = 1,
    StaticColor = 2,
    PseudoColor = 3,
    TrueColor = 4,
    DirectColor = 5,
};

pub const VisualType = extern struct {
    visual_id: u32,
    class: VisualClass,
    bits_per_rgb_value: u8,
    colormap_entries: u16,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    pad: [4]u8,
};

pub const Depth = extern struct {
    depth: u8,
    unused: [1]u8,
    visual_type_len: u16,
    pad: [4]u8,
};

pub const EventMask = enum(u32) {
    //NoEvent = 0b0,
    KeyPress = 0b1,
    KeyRelease = 0b10,
    ButtonPress = 0b100,
    ButtonRelease = 0b1000,
    EnterWindow = 0b10000,
    LeaveWindow = 0b100000,
    PointerMotion = 0b1000000,
    PointerMotionHint = 0b10000000,
    Button1Motion = 0b100000000,
    Button2Motion = 0b1000000000,
    Button3Motion = 0b10000000000,
    Button4Motion = 0b100000000000,
    Button5Motion = 0b1000000000000,
    ButtonMotion = 0b10000000000000,
    KeymapState = 0b100000000000000,
    Exposure = 0b1000000000000000,
    VisibilityChange = 0b10000000000000000,
    StructureNotify = 0b100000000000000000,
    ResizeRedirect = 0b1000000000000000000,
    SubstructureNotify = 0b10000000000000000000,
    SubstructureRedirect = 0b100000000000000000000,
    FocusChange = 0b1000000000000000000000,
    PropertyChange = 0b10000000000000000000000,
    ColormapChange = 0b100000000000000000000000,
    OwnerGrabButton = 0b1000000000000000000000000,
};

// Setup structs
pub const BackingStore = enum(u8) {
    NotUseful = 0,
    WhenMapped = 1,
    Always = 2,
};

pub const Screen = extern struct {
    root: u32,
    colormap: u32,
    white_pixel: u32,
    black_pixel: u32,

    current_input_masks: u32,
    width_in_pixels: u16,
    height_in_pixels: u16,
    width_in_millimeters: u16,
    height_in_millimeters: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,

    root_visual: u32,

    backing_stores: BackingStore,
    save_unders: u8,

    root_depth: u8,
    allowed_depths_len: u8,
};

pub const SetupRequest = extern struct {
    byte_order: u8 = switch (@import("builtin").cpu.arch.endian()) {
        .big => 'B',
        .little => 'l',
    },
    unused: u8 = 0,
    protocol_major_version: u16 = 11,
    procotol_minor_version: u16 = 0,
    auth_name_len: u16,
    auth_data_len: u16,
    pad: [2]u8 = [2]u8{ 0, 0 },
    // must send auth data and padding
};

pub const ImageByteOrder = enum(u8) {
    LSBFirst = 0,
    MSBFirst = 1,
};

pub const BitmapFormatBitOrder = enum(u8) {
    LeastSignificant = 0,
    MostSignificant = 1,
};

// Split Setup (response) in two, for easier reading
pub const SetupStatus = extern struct {
    status: u8,
    pad: u8,
    major_version: u16,
    minor_version: u16,
    reply_len: u16,
};

// rest of Setup response
pub const SetupContent = extern struct {
    release_number: u32,
    resource_id_base: u32,
    resource_id_mask: u32,
    motion_buffer_size: u32,
    vendor_len: u16,
    maximum_request_length: u16,
    roots_len: u8,
    pixmap_formats_len: u8,
    image_byte_order: ImageByteOrder,
    bitmap_format_bit_order: BitmapFormatBitOrder,
    bitmap_format_scanline_unit: u8,
    bitmap_format_scanline_pad: u8,
    min_keycode: u8,
    max_keycode: u8,
    pad: [4]u8,
};

// events

pub const ModMask = enum(u16) {
    Shift = 0b1,
    Lock = 0b10,
    Control = 0b100,
    One = 0b1000,
    Two = 0b10000,
    Three = 0b100000,
    Four = 0b1000000,
    Five = 0b10000000,
    Any = 0b1000000000000000,
};

pub const KeyButMask = enum(u16) {
    Shift = 0b1,
    Lock = 0b10,
    Control = 0b100,
    Mod1 = 0b1000,
    Mod2 = 0b10000,
    Mod3 = 0b100000,
    Mod4 = 0b1000000,
    Mod5 = 0b10000000,
    Button1 = 0b100000000,
    Button2 = 0b1000000000,
    Button3 = 0b10000000000,
    Button4 = 0b100000000000,
    Button5 = 0b1000000000000,
};

pub const KeyPress = extern struct {
    code: u8 = 2,
    keycode: u8,
    sequence_number: u16,
    time: u32,
    root_window: u32,
    event_window: u32,
    child_window: u32,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16, // KeyButMask
    same_screen: u8, // actually a bool
    pad: [1]u8,
};

pub const KeyRelease = extern struct {
    code: u8 = 3,
    keycode: u8,
    sequence_number: u16,
    time: u32,
    root_window: u32,
    event_window: u32,
    child_window: u32,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16, // KeyButMask
    same_screen: u8, // actually a bool
    pad: [1]u8,
};

pub const ButtonMask = enum(u16) {
    Button1 = 0b100000000,
    Button2 = 0b1000000000,
    Button3 = 0b10000000000,
    Button4 = 0b100000000000,
    Button5 = 0b1000000000000,
    ButtonAny = 0b1000000000000000,
};

pub const ButtonPress = extern struct {
    code: u8 = 4,
    keycode: u8,
    sequence_number: u16,
    time: u32,
    root_window: u32,
    event_window: u32,
    child_window: u32,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16, //keybutmask
    same_screen: u8, // actually a bool
    pad: [1]u8,
};

pub const ButtonRelease = extern struct {
    code: u8 = 5,
    keycode: u8,
    sequence_number: u16,
    time: u32,
    root_window: u32,
    event_window: u32,
    child_window: u32,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16, //keybutmask
    same_screen: u8, // actually a bool
    pad: [1]u8,
};

pub const Motion = enum(u8) {
    Normal = 0,
    Hint = 1,
};

pub const MotionNotify = extern struct {
    code: u8 = 6,
    detail: Motion,
    sequence_number: u16,
    time: u32,
    root_window: u32,
    event_window: u32,
    child_window: u32,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16, //keybutmask
    same_screen: u8, // actually a bool
    pad: [1]u8,
};

pub const NotifyDetail = enum(u8) {
    Ancestor,
    Virtual,
    Inferior,
    Nonlinear,
    NonlinearVirtual,
    Pointer,
    PointerRoot,
    None,
};

pub const NotifyMode = enum(u8) {
    Normal,
    Grab,
    Ungrab,
    WhileGrabbed,
};

pub const EnterNotify = extern struct {
    code: u8 = 7,
    detail: NotifyDetail,
    sequence_number: u16,
    time: u32,
    root: u32,
    event: u32,
    child: u32,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16, // keybutmask
    mode: NotifyMode,
    same_screen: u8, // actually a bool? or not
};

pub const LeaveNotify = extern struct {
    code: u8 = 8,
    detail: NotifyDetail,
    sequence_number: u16,
    time: u32,
    root: u32,
    event: u32,
    child: u32,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16, // keybutmask
    mode: NotifyMode,
    same_screen: u8, // actually a bool? or not
};

pub const FocusIn = extern struct {
    code: u8 = 9,
    detail: NotifyDetail,
    sequence_number: u16,
    event: u32,
    mode: NotifyMode,
    pad: [23]u8,
};

pub const FocusOut = extern struct {
    code: u8 = 10,
    detail: NotifyDetail,
    sequence_number: u16,
    event: u32,
    mode: NotifyMode,
    pad: [23]u8,
};

pub const KeymapNotify = extern struct {
    code: u8 = 11,
    keys: [31]u8,
};

pub const Expose = extern struct {
    code: u8 = 12,
    unused: [1]u8,
    sequence_number: u16,
    window_id: u32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    count: u16,
    pad: [11]u8,
};

pub const GraphicsExposure = extern struct {
    code: u8 = 13,
    unused: [1]u8,
    sequence_number: u16,
    drawable_id: u32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    minor_opcode: u16,
    count: u16,
    major_opcode: u8,
    pad: [11]u8,
};

pub const NoExposure = extern struct {
    code: u8 = 14,
    unused: [1]u8,
    sequence_number: u16,
    drawable_id: u32,
    minor_opcode: u16,
    major_opcode: u8,
    pad: [21]u8,
};

// TODO: fill rest of events

pub const Placeholder = extern struct {
    code: u8,
    unused: [1]u8,
    sequence_number: u16,
    rest: [28]u8,
};

pub const Visilibity = enum(u8) {
    Unobscured,
    PartiallyObscured,
    FullyObscured,
};

pub const VisibilityNotify = extern struct {
    code: u8 = 15,
    unused: [1]u8,
    sequence_number: u16,
    window_id: u32,
    state: Visilibity,
    pad: [23]u8,
};

pub const CreateNotify = extern struct {
    code: u8 = 16,
    unused: [1]u8,
    sequence_number: u16,
    window_id: u32,
    parent_id: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    override_redirect: u8,
    pad: [9]u8,
};

pub const DestroyNotify = extern struct {
    code: u8 = 16,
    unused: [1]u8,
    sequence_number: u16,
    event: u32,
    window_id: u32,
    pad: [20]u8,
};

pub const UnmapNotify = Placeholder;
pub const MapNotify = Placeholder;
pub const MapRequest = Placeholder;
pub const ReparentNotify = Placeholder;

pub const ConfigureNotify = extern struct {
    code: u8 = 22,
    unused: u8,
    sequence_number: u16,
    event: u32,
    window_id: u32,
    sibling: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    override_redirect: bool,
    pad: [5]u8,
};

pub const ConfigureRequest = extern struct {
    code: u8 = 23,
    stack_mode: enum(u8) {
        Above,
        Below,
        TopIf,
        BottomIf,
        Opposite,
    },
    sequence_number: u16,
    parent: u32,
    window_id: u32,
    sibling: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    value_mask: u16,
    pad: [4]u8,
};

pub const GravityNotify = Placeholder;

pub const ResizeRequest = extern struct {
    code: u8 = 25,
    unused: [1]u8,
    sequence_number: u16,
    window_id: u32,
    width: u16,
    height: u16,
    pad: [20]u8,
};

pub const CirculateNotify = Placeholder;
pub const CirculateRequest = Placeholder;

pub const PropertyNotify = extern struct {
    code: u8 = 28,
    unused: u8,
    sequence_number: u16,
    window_id: u32,
    atom: u32,
    timestamp: u32,
    state: enum(u8) {
        NewValue,
        Deleted,
    },
    pad: [15]u8,
};

pub const SelectionClear = Placeholder;
pub const SelectionRequest = Placeholder;
pub const SelectionNotify = Placeholder;
pub const ColormapNotify = Placeholder;

pub const ClientMessage = extern struct {
    code: u8 = 33,
    format: u8,
    sequence_number: u16,
    window_id: u32,
    data_Type: u32,
    data: [20]u8,
};

pub const MappingNotify = extern struct {
    code: u8 = 34,
    unused: [1]u8,
    sequence_number: u16,
    request: enum(u8) {
        Modified,
        Keyboard,
        Pointer,
    },
    keycode: u8,
    count: u8,
    pad: [25]u8,
};

// Requests

pub const WindowClass = enum(u16) {
    Parent = 0,
    InputOutput = 1,
    InputOnly = 2,
};

pub const WindowMask = enum(u32) {
    BackgroundPixmap = 1,
    BackgroundPixel = 2,
    BorderPixmap = 4,
    BorderPixel = 8,
    BitGravity = 16,
    WinGravity = 32,
    BackingStore = 64,
    BackingPlanes = 128,
    BackingPixel = 256,
    OverrideRedirect = 512,
    SaveUnder = 1024,
    EventMask = 2048,
    DoNotPropagateMask = 4096,
    Colormap = 8192,
    Cursor = 16348,
};

pub const WindowValue = struct {
    BackgroundPixmap: ?u32 = null,
    BackgroundPixel: ?u32 = null,
    BorderPixmap: ?u32 = null,
    BorderPixel: ?u32 = null,
    BitGravity: ?Gravity = null,
    WinGravity: ?Gravity = null,
    BackingStore: ?BackingStore = null,
    BackingPlanes: ?u32 = null,
    BackingPixel: ?u32 = null,
    OverrideRedirect: ?bool = null,
    SaveUnder: ?bool = null,
    EventMask: ?u32 = null,
    DoNotPropagateMask: ?u32 = null,
    Colormap: ?u32 = null,
    Cursor: ?u32 = null,
};

pub const BackPixmap = enum(u32) {
    None,
    ParentRelative,
};

pub const Gravity = enum(u8) {
    BitForget,
    WinUnmap,
    NorthWest,
    North,
    NorthEast,
    West,
    Center,
    East,
    SouthWest,
    South,
    SouthEast,
    Static,
};

pub const CreateWindow = extern struct {
    opcode: u8 = 1,
    depth: u8,
    length: u16 = (@sizeOf(@This()) / 4),
    window_id: u32,
    parent_id: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    window_class: WindowClass,
    visual_id: u32,
    value_mask: u32 = 0,
};

pub const ChangeWindowAttributes = extern struct {
    opcode: u8 = 2,
    unused: u8 = 0,
    length: u16 = (@sizeOf(@This()) / 4),
    window_id: u32,
    value_mask: u32 = 0,
};

pub const GetWindowAttributes = extern struct {
    opcode: u8 = 3,
    unused: u8 = 0,
    length: u16 = (@sizeOf(@This()) / 4),
    window_id: u32,
};

// TODO: GetWindowAttributes reply?

pub const DestroyWindow = extern struct {
    opcode: u8 = 4,
    pad: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
};

pub const DestroySubwindows = extern struct {
    opcode: u8 = 5,
    pad: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
};

pub const ChangeSaveSet = extern struct {
    opcode: u8 = 6,
    mode: enum(u8) { Insert, Delete } = .Insert,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
};

pub const ReparentWindow = extern struct {
    opcode: u8 = 7,
    unused: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
    parent_window_id: u32,
    x: i16 = 0,
    y: i16 = 0,
};

pub const MapWindow = extern struct {
    opcode: u8 = 8,
    pad: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
};

pub const MapSubwindows = extern struct {
    opcode: u8 = 9,
    pad: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
};

pub const UnmapWindow = extern struct {
    opcode: u8 = 10,
    pad: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
};

pub const UnmapSubwindows = extern struct {
    opcode: u8 = 11,
    pad: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
};

pub const ConfigureWindowMask = enum(u16) {
    X = 0b1,
    Y = 0b10,
    Width = 0b100,
    Height = 0b1000,
    BorderWidth = 0b10000,
    Sibling = 0b100000,
    StackMode = 0b1000000,
};

pub const StackMode = enum(u8) {
    Above,
    Below,
    TopIf,
    BottomIf,
    Opposite,
};

pub const ConfigureWindowValues = struct {
    Y: ?i16,
    X: ?i16,
    Width: ?u16,
    Height: ?u16,
    BorderWidth: ?u16,
    Sibling: ?u32,
    StackMode: ?StackMode,
};

pub const ConfigureWindow = extern struct {
    opcode: u8 = 12,
    unused: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
    values: u16,
    pad: [2]u8 = [2]u8{ 0, 0 },
};

pub const CirculateWindow = extern struct {
    opcode: u8 = 13,
    direction: enum(u8) { RaiseLowest, LowerHighest } = .RaiseLowest,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
};

pub const InternAtom = extern struct {
    opcode: u8 = 16,
    only_if_exists: bool = false,
    length: u16 = @sizeOf(@This()) / 4,
    length_of_name: u16,
    unused: [2]u8 = [2]u8{ 0, 0 },
};

pub const InternAtomReply = extern struct {
    reply: u8,
    pad: u8,
    sequence_number: u16,
    reply_length: u32,
    atom: u32,
    unused: [20]u8,
};

pub const ChangeProperty = extern struct {
    opcode: u8 = 18,
    mode: enum(u8) { Replace, Prepend, Append } = .Replace,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
    property: u32,
    property_type: u32,
    format: u8 = 8,
    unused: [3]u8 = .{ 0, 0, 0 },
    length_of_data: u32 = 0,
};

pub const DeleteProperty = extern struct {
    opcode: u8 = 19,
    unused: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    window_id: u32,
    property: u32,
};

pub const GetProperty = extern struct {
    opcode: u8 = 20,
    delete: bool = false,
    length: u16 = (@sizeOf(@This()) / 4),
    window_id: u32 = 0,
    property: u32,
    property_type: u32 = 0,
    long_offset: u32 = 0,
    long_length: u32 = 0,
};

pub const GetPropertyReply = extern struct {
    code: u8 = 1,
    format: u8,
    sequence_number: u16,
    reply_length: u32,
    property_type: u32,
    bytes_after: u32,
    value_len: u32,
    pad: [12]u8,
};

pub const ListProperties = extern struct {
    opcode: u8 = 21,
    unused: u8,
    length: u16 = (@sizeOf(@This()) / 4),
    window_id: u32,
};

//TODO: ListProperties Reply

pub const ClientMessageEvent = extern struct {
    code: u8 = 33,
    format: u8 = 32,
    sequence_number: u16 = 0,
    window_id: u32,
    message_type: u32,
    data: [5]u32 = .{ 0, 0, 0, 0, 0 },
};

pub const SendEvent = extern struct {
    opcode: u8 = 25,
    propagate: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    destination: u32,
    event_mask: u32 = 0,
    event: [32]u8,
};

pub const CreatePixmap = extern struct {
    opcode: u8 = 53,
    depth: u8,
    length: u16 = (@sizeOf(@This()) / 4),
    pixmap_id: u32,
    drawable_id: u32,
    width: u16,
    height: u16,
};

pub const FreePixmap = extern struct {
    opcode: u8 = 54,
    unused: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    pixmap_id: u32,
};

pub const GraphicContextMask = enum(u32) {
    Function = 0x00000001,
    PlaneMask = 0x00000002,
    Foreground = 0x00000004,
    Background = 0x00000008,
    LineWidth = 0x00000010,
    LineStyle = 0x00000020,
    CapStyle = 0x00000040,
    JoinStyle = 0x00000080,
    FillStyle = 0x00000100,
    FillRule = 0x00000200,
    Tile = 0x00000400,
    Stipple = 0x00000800,
    TileStippleOriginX = 0x00001000,
    TileStippleOriginY = 0x00002000,
    Font = 0x00004000,
    SubwindowMode = 0x00008000,
    GraphicsExposures = 0x00010000,
    ClipOriginX = 0x00020000,
    ClipOriginY = 0x00040000,
    ClipMask = 0x00080000,
    DashOffset = 0x00100000,
    DashList = 0x00200000,
    ArcMode = 0x00400000,
};

pub const Function = enum(u8) {
    Clear,
    And,
    AndReverse,
    Copy,
    AndInverted,
    NoOp,
    Xor,
    Or,
    Nor,
    Equiv,
    Invert,
    OrReverse,
    CopyInverted,
    OrInverted,
    Nand,
    Set,
};

pub const LineStyle = enum(u8) {
    Solid,
    OnOffDash,
    DoubleDash,
};
pub const CapStyle = enum(u8) {
    NotLast,
    Butt,
    Round,
    Projecting,
};

pub const JoinStyle = enum(u8) {
    Miter,
    OnOffDash,
    Round,
};

pub const FillStyle = enum(u8) {
    Solid,
    Tiled,
    Stippled,
    OpaqueStippled,
};

pub const FillRule = enum(u8) {
    EvenOdd,
    Winding,
};

pub const SubwindowMode = enum(u8) {
    ClipByChildren,
    IncludeInferiors,
};

pub const ArcMode = enum(u8) {
    Chord,
    PieSlice,
};

pub const GraphicContextValue = struct {
    Function: ?Function = null,
    PlaneMask: ?u32 = null,
    Foreground: ?u32 = null,
    Background: ?u32 = null,
    LineWidth: ?u16 = null,
    LineStyle: ?LineStyle = null,
    CapStyle: ?u32 = null,
    JoinStyle: ?u32 = null,
    FillStyle: ?u32 = null,
    FillRule: ?u32 = null,
    Tile: ?u32 = null,
    Stipple: ?u32 = null,
    TileStippleOriginX: ?u32 = null,
    TileStippleOriginY: ?u32 = null,
    Font: ?u32 = null,
    SubwindowMode: ?u32 = null,
    GraphicsExposures: ?u32 = null,
    ClipOriginX: ?u32 = null,
    ClipOriginY: ?u32 = null,
    ClipMask: ?u32 = null,
    DashOffset: ?u32 = null,
    DashList: ?u32 = null,
    ArcMode: ?u32 = null,
};

pub const CreateGraphicContext = extern struct {
    opcode: u8 = 55,
    unused: u8 = 0,
    length: u16 = (@sizeOf(@This()) / 4),
    graphic_context_id: u32,
    drawable_id: u32,
    value_mask: u32 = 0,
};

pub const ChangeGraphicContext = extern struct {
    opcode: u8 = 56,
    unused: u8 = 0,
    length: u16 = (@sizeOf(@This()) / 4),
    graphic_context_id: u32,
    value_mask: u32 = 0,
};

pub const CopyGraphicContext = extern struct {
    opcode: u8 = 57,
    unused: u8 = 0,
    length: u16 = (@sizeOf(@This()) / 4),
    src_graphic_context_id: u32,
    dst_graphic_context_id: u32,
    value_mask: u32 = 0,
};

pub const FreeGraphicContext = extern struct {
    opcode: u8 = 60,
    unused: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    graphic_context_id: u32,
};

pub const ClearArea = extern struct {
    opcode: u8 = 61,
    exposures: bool = false,
    length: u16 = (@sizeOf(@This()) / 4),
    window_id: u32,
    x: i16 = 0,
    y: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
};

pub const CopyArea = extern struct {
    opcode: u8 = 62,
    pad: u8 = 0,
    length: u16 = (@sizeOf(@This()) / 4),
    src_drawable_id: u32,
    dst_drawable_id: u32,
    graphic_context_id: u32,
    src_x: i16 = 0,
    src_y: i16 = 0,
    dst_x: i16 = 0,
    dst_y: i16 = 0,
    width: u16,
    height: u16,
};

pub const ImageFormat = enum(u8) {
    XYBitmap = 0,
    XYPixmap = 1,
    ZPixmap = 2,
};

pub const PutImage = extern struct {
    opcode: u8 = 72,
    format: ImageFormat = .ZPixmap,
    length: u16 = (@sizeOf(@This()) / 4),
    drawable_id: u32,
    graphic_context_id: u32,
    width: u16,
    height: u16,
    x: i16,
    y: i16,
    left_pad: u8 = 0,
    depth: u8,
    pad: [2]u8 = .{ 0, 0 },
};

pub const GetKeyboardMapping = extern struct {
    opcode: u8 = 101,
    unused: u8 = 0,
    length: u16 = @sizeOf(@This()) / 4,
    first_keycode: u8,
    count: u8,
    pad: [2]u8 = .{ 0, 0 },
};

pub const GetKeyboardMappingReply = extern struct {
    code: u8 = 1,
    keysyms_per_keycode: u8,
    sequence_number: u16,
    reply_length: u32,
    pad: [24]u8,
};

pub const NoOperation = extern struct {
    opcode: u8 = 127,
    unused: u8 = 0,
    length: u16 = (@sizeOf(@This()) / 4),
};

// Error handling

pub const ErrorMessage = extern struct {
    message_code: u8, // already read to know it is an error
    error_code: ErrorCodes,
    sequence_number: u16,
    details: u32,
    minor_opcode: u16,
    major_opcode: u8,
    pad: [21]u8, // error messages always have 32 bytes total
};

pub const ErrorCodes = enum(u8) {
    NoError, // ??
    Request,
    Value,
    Window,
    Pixmap,
    Atom,
    Cursor,
    Font,
    Match,
    Drawable,
    Access,
    Alloc,
    Colormap,
    GContext,
    IDChoice,
    Name,
    Length,
    Implementation,
};
