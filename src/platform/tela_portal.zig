//! Capturar a tela no Wayland: o portal (org.freedesktop.portal.ScreenCast)
//! mostra o diálogo do sistema para escolher a tela ou a janela, e os quadros
//! chegam pelo PipeWire. As duas bibliotecas (libdbus-1 e libpipewire-0.3) são
//! abertas na hora, como a do ícone da bandeja (platform/sni.zig): sem elas, a
//! transmissão diz o que falta e o resto do app nem percebe.
//!
//! O portal responde cada pedido com um sinal `Response` num objeto
//! /org/freedesktop/portal/desktop/request/<remetente>/<token>: o pedido é feito,
//! e a resposta é esperada nessa fila (o diálogo pode levar o tempo que a pessoa
//! quiser; parar a transmissão no meio cancela). Os quadros vêm em memória comum
//! (MemPtr ou MemFd; sem DMA-BUF, que precisaria de EGL), copiados para um
//! buffer que a thread do codificador lê.
const std = @import("std");
const c = @import("c");
const video_codec = @import("video_codec.zig");

const alloc = std.heap.c_allocator;

fn ms() i64 {
    return @intCast(c.SDL_GetTicks());
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (@import("debug_log.zig").isOn() or c.SDL_getenv("LARPER_VOICE_DEBUG") != null) std.log.info("tela: " ++ fmt, args);
}

// --- libdbus -----------------------------------------------------------------

const Conn = opaque {};
const Msg = opaque {};
/// DBusMessageIter tem 72 bytes e DBusError 32: os dois com folga.
const Iter = [16]u64;
const Err = extern struct { name: ?[*:0]const u8 = null, message: ?[*:0]const u8 = null, rest: [6]usize = @splat(0) };

const DBus = struct {
    dbus_error_init: *const fn (*Err) callconv(.c) void,
    dbus_error_free: *const fn (*Err) callconv(.c) void,
    dbus_error_is_set: *const fn (*const Err) callconv(.c) u32,
    dbus_bus_get_private: *const fn (c_int, *Err) callconv(.c) ?*Conn,
    dbus_bus_get_unique_name: *const fn (*Conn) callconv(.c) ?[*:0]const u8,
    dbus_bus_add_match: *const fn (*Conn, [*:0]const u8, ?*Err) callconv(.c) void,
    dbus_connection_set_exit_on_disconnect: *const fn (*Conn, u32) callconv(.c) void,
    dbus_connection_close: *const fn (*Conn) callconv(.c) void,
    dbus_connection_unref: *const fn (*Conn) callconv(.c) void,
    dbus_connection_send_with_reply_and_block: *const fn (*Conn, *Msg, c_int, *Err) callconv(.c) ?*Msg,
    dbus_connection_read_write: *const fn (*Conn, c_int) callconv(.c) u32,
    dbus_connection_pop_message: *const fn (*Conn) callconv(.c) ?*Msg,
    dbus_message_new_method_call: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Msg,
    dbus_message_unref: *const fn (*Msg) callconv(.c) void,
    dbus_message_get_type: *const fn (*Msg) callconv(.c) c_int,
    dbus_message_get_path: *const fn (*Msg) callconv(.c) ?[*:0]const u8,
    dbus_message_get_member: *const fn (*Msg) callconv(.c) ?[*:0]const u8,
    dbus_message_iter_init: *const fn (*Msg, *Iter) callconv(.c) u32,
    dbus_message_iter_get_arg_type: *const fn (*Iter) callconv(.c) c_int,
    dbus_message_iter_get_basic: *const fn (*Iter, *anyopaque) callconv(.c) void,
    dbus_message_iter_next: *const fn (*Iter) callconv(.c) u32,
    dbus_message_iter_recurse: *const fn (*Iter, *Iter) callconv(.c) void,
    dbus_message_iter_init_append: *const fn (*Msg, *Iter) callconv(.c) void,
    dbus_message_iter_append_basic: *const fn (*Iter, c_int, *const anyopaque) callconv(.c) u32,
    dbus_message_iter_open_container: *const fn (*Iter, c_int, ?[*:0]const u8, *Iter) callconv(.c) u32,
    dbus_message_iter_close_container: *const fn (*Iter, *Iter) callconv(.c) u32,
};

fn loadFns(comptime T: type, names: []const [*:0]const u8) ?T {
    for (names) |n| {
        const lib = c.SDL_LoadObject(n) orelse continue;
        var out: T = undefined;
        var ok = true;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |fname, ftype| {
            if (c.SDL_LoadFunction(lib, fname ++ "")) |p| {
                @field(out, fname) = @as(ftype, @ptrCast(p));
            } else ok = false;
        }
        if (ok) return out;
        c.SDL_UnloadObject(lib);
    }
    return null;
}

var dbus_fns: ?DBus = null;
var dbus_tried = false;

fn dbusApi() ?*const DBus {
    if (!dbus_tried) {
        dbus_tried = true;
        dbus_fns = loadFns(DBus, &.{ "libdbus-1.so.3", "libdbus-1.so" });
    }
    return if (dbus_fns) |*f| f else null;
}

const DT = struct {
    const invalid: c_int = 0;
    const boolean: c_int = 'b';
    const uint32: c_int = 'u';
    const int32: c_int = 'i';
    const string: c_int = 's';
    const object_path: c_int = 'o';
    const unix_fd: c_int = 'h';
    const array: c_int = 'a';
    const variant: c_int = 'v';
    const dict_entry: c_int = 'e';
    const @"struct": c_int = 'r';
};

const bus = "org.freedesktop.portal.Desktop";
const obj = "/org/freedesktop/portal/desktop";
const iface = "org.freedesktop.portal.ScreenCast";

// --- PipeWire ----------------------------------------------------------------

const PwThreadLoop = opaque {};
const PwLoop = opaque {};
const PwContext = opaque {};
const PwCore = opaque {};
const PwStream = opaque {};
const PwProps = opaque {};

const SpaHook = extern struct { p: [6]?*anyopaque = @splat(null) };
const SpaChunk = extern struct { offset: u32, size: u32, stride: i32, flags: i32 };
const SpaData = extern struct { typ: u32, flags: u32, fd: i64, mapoffset: u32, maxsize: u32, data: ?[*]u8, chunk: ?*SpaChunk };
const SpaBuffer = extern struct { n_metas: u32, n_datas: u32, metas: ?*anyopaque, datas: [*]SpaData };
const PwBuffer = extern struct { buffer: *SpaBuffer, user_data: ?*anyopaque, size: u64, requested: u64 };

const StreamEvents = extern struct {
    version: u32 = 2,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (?*anyopaque, c_int, c_int, ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const anyopaque = null,
    io_changed: ?*const anyopaque = null,
    param_changed: ?*const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) void = null,
    add_buffer: ?*const anyopaque = null,
    remove_buffer: ?*const anyopaque = null,
    process: ?*const fn (?*anyopaque) callconv(.c) void = null,
    drained: ?*const anyopaque = null,
    command: ?*const anyopaque = null,
    trigger_done: ?*const anyopaque = null,
};

const Pw = struct {
    pw_init: *const fn (?*c_int, ?*anyopaque) callconv(.c) void,
    pw_thread_loop_new: *const fn ([*:0]const u8, ?*const anyopaque) callconv(.c) ?*PwThreadLoop,
    pw_thread_loop_get_loop: *const fn (*PwThreadLoop) callconv(.c) *PwLoop,
    pw_thread_loop_start: *const fn (*PwThreadLoop) callconv(.c) c_int,
    pw_thread_loop_stop: *const fn (*PwThreadLoop) callconv(.c) void,
    pw_thread_loop_destroy: *const fn (*PwThreadLoop) callconv(.c) void,
    pw_thread_loop_lock: *const fn (*PwThreadLoop) callconv(.c) void,
    pw_thread_loop_unlock: *const fn (*PwThreadLoop) callconv(.c) void,
    pw_context_new: *const fn (*PwLoop, ?*PwProps, usize) callconv(.c) ?*PwContext,
    pw_context_destroy: *const fn (*PwContext) callconv(.c) void,
    pw_context_connect_fd: *const fn (*PwContext, c_int, ?*PwProps, usize) callconv(.c) ?*PwCore,
    pw_core_disconnect: *const fn (*PwCore) callconv(.c) c_int,
    pw_properties_new_string: *const fn ([*:0]const u8) callconv(.c) ?*PwProps,
    pw_stream_new: *const fn (*PwCore, [*:0]const u8, ?*PwProps) callconv(.c) ?*PwStream,
    pw_stream_add_listener: *const fn (*PwStream, *SpaHook, *const StreamEvents, ?*anyopaque) callconv(.c) void,
    pw_stream_connect: *const fn (*PwStream, c_int, u32, c_int, [*]const *const anyopaque, u32) callconv(.c) c_int,
    pw_stream_disconnect: *const fn (*PwStream) callconv(.c) c_int,
    pw_stream_destroy: *const fn (*PwStream) callconv(.c) void,
    pw_stream_dequeue_buffer: *const fn (*PwStream) callconv(.c) ?*PwBuffer,
    pw_stream_queue_buffer: *const fn (*PwStream, *PwBuffer) callconv(.c) c_int,
    pw_stream_update_params: *const fn (*PwStream, [*]const *const anyopaque, u32) callconv(.c) c_int,
};

var pw_fns: ?Pw = null;
var pw_tried = false;

fn pwApi() ?*const Pw {
    if (!pw_tried) {
        pw_tried = true;
        pw_fns = loadFns(Pw, &.{ "libpipewire-0.3.so.0", "libpipewire-0.3.so" });
        if (pw_fns) |*f| f.pw_init(null, null);
    }
    return if (pw_fns) |*f| f else null;
}

/// O que falta para capturar pelo portal (null = nada).
pub fn missing() ?[]const u8 {
    if (dbusApi() == null) return "libdbus-1";
    if (pwApi() == null) return "libpipewire-0.3";
    return null;
}

// --- SPA POD (o formato binário dos parâmetros do PipeWire) ------------------

const spa = struct {
    const type_id: u32 = 3;
    const type_int: u32 = 4;
    const type_rect: u32 = 10;
    const type_frac: u32 = 11;
    const type_object: u32 = 15;
    const type_choice: u32 = 19;
    const object_format: u32 = 0x40003;
    const object_buffers: u32 = 0x40004;
    const param_enum_format: u32 = 3;
    const param_format: u32 = 4;
    const param_buffers: u32 = 5;
    const format_media_type: u32 = 1;
    const format_media_subtype: u32 = 2;
    const format_video_format: u32 = 0x20001;
    const format_video_size: u32 = 0x20003;
    const format_video_framerate: u32 = 0x20004;
    const media_video: u32 = 2;
    const subtype_raw: u32 = 1;
    const buffers_data_type: u32 = 6;
    const choice_range: u32 = 1;
    const choice_enum: u32 = 3;
    const choice_flags: u32 = 4;
    const data_memptr: u32 = 1;
    const data_memfd: u32 = 2;
    const chunk_corrupted: i32 = 1;
    // spa_video_format
    const RGBx: u32 = 7;
    const BGRx: u32 = 8;
    const xRGB: u32 = 9;
    const xBGR: u32 = 10;
    const RGBA: u32 = 11;
    const BGRA: u32 = 12;
};

fn pixOf(f: u32) ?video_codec.PixFmt {
    return switch (f) {
        spa.BGRx => .bgrx,
        spa.BGRA => .bgra,
        spa.RGBx => .rgbx,
        spa.RGBA => .rgba,
        spa.xRGB => .xrgb,
        spa.xBGR => .xbgr,
        else => null,
    };
}

pub const PodWriter = struct {
    buf: [1024]u8 align(8) = undefined,
    len: usize = 0,

    fn put(w: *PodWriter, v: u32) void {
        std.mem.writeInt(u32, w.buf[w.len..][0..4], v, .little);
        w.len += 4;
    }

    fn pad(w: *PodWriter) void {
        while (w.len % 8 != 0) {
            w.buf[w.len] = 0;
            w.len += 1;
        }
    }

    pub fn beginObject(w: *PodWriter, typ: u32, param: u32) usize {
        const at = w.len;
        w.put(0); // tamanho, depois
        w.put(spa.type_object);
        w.put(typ);
        w.put(param);
        return at;
    }

    pub fn endObject(w: *PodWriter, at: usize) void {
        std.mem.writeInt(u32, w.buf[at..][0..4], @intCast(w.len - at - 8), .little);
    }

    pub fn prop(w: *PodWriter, key: u32) void {
        w.put(key);
        w.put(0);
    }

    pub fn id(w: *PodWriter, v: u32) void {
        w.put(4);
        w.put(spa.type_id);
        w.put(v);
        w.pad();
    }

    /// Escolha entre valores de 4 ou 8 bytes (`vals` em palavras de 32 bits).
    pub fn choice(w: *PodWriter, kind: u32, child_type: u32, child_size: u32, vals: []const u32) void {
        w.put(16 + @as(u32, @intCast(vals.len)) * 4);
        w.put(spa.type_choice);
        w.put(kind);
        w.put(0);
        w.put(child_size);
        w.put(child_type);
        for (vals) |v| w.put(v);
        w.pad();
    }

    pub fn bytes(w: *const PodWriter) []const u8 {
        return w.buf[0..w.len];
    }
};

/// O que aceitamos: vídeo cru em 4 bytes por pixel, de qualquer tamanho.
pub fn enumFormat(w: *PodWriter, fps: u32) void {
    const at = w.beginObject(spa.object_format, spa.param_enum_format);
    w.prop(spa.format_media_type);
    w.id(spa.media_video);
    w.prop(spa.format_media_subtype);
    w.id(spa.subtype_raw);
    w.prop(spa.format_video_format);
    w.choice(spa.choice_enum, spa.type_id, 4, &.{ spa.BGRx, spa.BGRx, spa.BGRA, spa.RGBx, spa.RGBA, spa.xRGB, spa.xBGR });
    w.prop(spa.format_video_size);
    w.choice(spa.choice_range, spa.type_rect, 8, &.{ 1920, 1080, 1, 1, 8192, 8192 });
    w.prop(spa.format_video_framerate);
    w.choice(spa.choice_range, spa.type_frac, 8, &.{ fps, 1, 0, 1, 360, 1 });
    w.endObject(at);
}

/// Buffers em memória comum (MemPtr ou MemFd), que dá para ler sem a GPU.
fn buffersParam(w: *PodWriter) void {
    const at = w.beginObject(spa.object_buffers, spa.param_buffers);
    w.prop(spa.buffers_data_type);
    w.choice(spa.choice_flags, spa.type_int, 4, &.{(1 << spa.data_memptr) | (1 << spa.data_memfd)});
    w.endObject(at);
}

/// O formato combinado (o Format que o PipeWire manda): o tipo de pixel e o tamanho.
pub const Negotiated = struct { fmt: u32 = 0, w: u32 = 0, h: u32 = 0 };

pub fn parseFormat(pod: []const u8) ?Negotiated {
    if (pod.len < 16) return null;
    const size = std.mem.readInt(u32, pod[0..4], .little);
    if (std.mem.readInt(u32, pod[4..8], .little) != spa.type_object) return null;
    const end = @min(pod.len, 8 + @as(usize, size));
    var out: Negotiated = .{};
    var i: usize = 16;
    while (i + 16 <= end) {
        const key = std.mem.readInt(u32, pod[i..][0..4], .little);
        const vsize = std.mem.readInt(u32, pod[i + 8 ..][0..4], .little);
        var vtype = std.mem.readInt(u32, pod[i + 12 ..][0..4], .little);
        var body = i + 16;
        if (body + vsize > end) return null;
        if (vtype == spa.type_choice and vsize >= 16) {
            vtype = std.mem.readInt(u32, pod[body + 12 ..][0..4], .little);
            body += 16;
        }
        switch (key) {
            spa.format_video_format => if (vtype == spa.type_id and body + 4 <= end) {
                out.fmt = std.mem.readInt(u32, pod[body..][0..4], .little);
            },
            spa.format_video_size => if (vtype == spa.type_rect and body + 8 <= end) {
                out.w = std.mem.readInt(u32, pod[body..][0..4], .little);
                out.h = std.mem.readInt(u32, pod[body + 4 ..][0..4], .little);
            },
            else => {},
        }
        i += 16 + ((vsize + 7) & ~@as(usize, 7));
    }
    return out;
}

// --- A captura ---------------------------------------------------------------

pub const Error = error{ Missing, NoPortal, Cancelled, Failed };

pub const Portal = struct {
    // D-Bus
    conn: ?*Conn = null,
    session: [256]u8 = undefined,
    session_len: usize = 0,
    sender: [128]u8 = undefined,
    sender_len: usize = 0,
    token_n: u32 = 0,
    // PipeWire
    node: u32 = 0,
    fd: c_int = -1,
    loop: ?*PwThreadLoop = null,
    context: ?*PwContext = null,
    core: ?*PwCore = null,
    stream: ?*PwStream = null,
    hook: SpaHook = .{},
    events: StreamEvents = .{},
    // Os quadros (escritos na thread do PipeWire).
    mutex: ?*c.SDL_Mutex = null,
    cond: ?*c.SDL_Condition = null,
    neg: Negotiated = .{},
    frame: std.ArrayList(u8) = .empty,
    frame_w: u32 = 0,
    frame_h: u32 = 0,
    frame_fmt: video_codec.PixFmt = .bgrx,
    seq: u64 = 0,
    taken: u64 = 0,
    /// A transmissão do PipeWire parou (a pessoa fechou pelo sistema, erro).
    ended: std.atomic.Value(bool) = .init(false),
    // A cópia que o codificador lê, sem segurar o mutex.
    local: std.ArrayList(u8) = .empty,
    fps: u32 = 30,

    /// Pergunta ao sistema o que capturar e liga o PipeWire. Bloqueia enquanto o
    /// diálogo está aberto; `stop` cancela.
    pub fn open(p: *Portal, fps: u32, stop: *const std.atomic.Value(bool)) Error!void {
        p.fps = fps;
        const db = dbusApi() orelse return error.Missing;
        const pw = pwApi() orelse return error.Missing;
        p.mutex = c.SDL_CreateMutex() orelse return error.Failed;
        p.cond = c.SDL_CreateCondition() orelse return error.Failed;
        var err: Err = .{};
        db.dbus_error_init(&err);
        defer db.dbus_error_free(&err);
        p.conn = db.dbus_bus_get_private(0, &err) orelse return error.NoPortal;
        db.dbus_connection_set_exit_on_disconnect(p.conn.?, 0);
        const uname = db.dbus_bus_get_unique_name(p.conn.?) orelse return error.NoPortal;
        // ":1.234" -> "1_234"
        for (std.mem.span(uname)[1..]) |ch| {
            if (p.sender_len >= p.sender.len) return error.Failed;
            p.sender[p.sender_len] = if (ch == '.') '_' else ch;
            p.sender_len += 1;
        }
        db.dbus_bus_add_match(p.conn.?, "type='signal',interface='org.freedesktop.portal.Request',member='Response'", null);

        try p.createSession(db, stop);
        p.selectSources(db, stop, 2) catch |e| switch (e) {
            // Sem o cursor desenhado no vídeo: pede sem ele.
            error.Failed => try p.selectSources(db, stop, 1),
            else => return e,
        };
        try p.startCast(db, stop);
        try p.openRemote(db);
        try p.connectPw(pw);
    }

    fn token(p: *Portal, buf: []u8) [:0]const u8 {
        p.token_n += 1;
        return std.fmt.bufPrintSentinel(buf, "larper{d}_{d}", .{ @as(u32, @truncate(@as(u64, @intCast(ms())))), p.token_n }, 0) catch unreachable;
    }

    fn sessionZ(p: *Portal, buf: []u8) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}", .{p.session[0..p.session_len]}, 0) catch "";
    }

    /// Abre o a{sv} das opções.
    fn openDict(db: *const DBus, args: *Iter, dict: *Iter) void {
        _ = db.dbus_message_iter_open_container(args, DT.array, "{sv}", dict);
    }

    fn entry(db: *const DBus, dict: *Iter, key: [*:0]const u8, typ: c_int, sig: [*:0]const u8, value: *const anyopaque) void {
        var e: Iter = undefined;
        var v: Iter = undefined;
        _ = db.dbus_message_iter_open_container(dict, DT.dict_entry, null, &e);
        const k: [*:0]const u8 = key;
        _ = db.dbus_message_iter_append_basic(&e, DT.string, @ptrCast(&k));
        _ = db.dbus_message_iter_open_container(&e, DT.variant, sig, &v);
        _ = db.dbus_message_iter_append_basic(&v, typ, value);
        _ = db.dbus_message_iter_close_container(&e, &v);
        _ = db.dbus_message_iter_close_container(dict, &e);
    }

    fn call(p: *Portal, db: *const DBus, m: *Msg) Error!*Msg {
        var err: Err = .{};
        db.dbus_error_init(&err);
        defer db.dbus_error_free(&err);
        const reply = db.dbus_connection_send_with_reply_and_block(p.conn.?, m, 10_000, &err) orelse {
            if (err.message) |msg| dbg("portal: {s}", .{std.mem.span(msg)});
            if (err.name) |n| if (std.mem.indexOf(u8, std.mem.span(n), "ServiceUnknown") != null or std.mem.indexOf(u8, std.mem.span(n), "UnknownMethod") != null or std.mem.indexOf(u8, std.mem.span(n), "UnknownInterface") != null) return error.NoPortal;
            return error.Failed;
        };
        return reply;
    }

    /// Espera o `Response` do pedido `tok`: 0 = deu certo (os resultados ficam em
    /// `out`, que quem chama solta), 1 = cancelado no diálogo.
    fn waitResponse(p: *Portal, db: *const DBus, tok: []const u8, stop: *const std.atomic.Value(bool)) Error!*Msg {
        var want_buf: [320]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ p.sender[0..p.sender_len], tok }) catch return error.Failed;
        const deadline = ms() + 10 * 60 * 1000;
        while (ms() < deadline) {
            if (stop.load(.acquire)) return error.Cancelled;
            if (db.dbus_connection_read_write(p.conn.?, 100) == 0) return error.Failed;
            while (db.dbus_connection_pop_message(p.conn.?)) |m| {
                const is_sig = db.dbus_message_get_type(m) == 4;
                const path = if (db.dbus_message_get_path(m)) |s| std.mem.span(s) else "";
                const member = if (db.dbus_message_get_member(m)) |s| std.mem.span(s) else "";
                if (is_sig and std.mem.eql(u8, member, "Response") and std.mem.eql(u8, path, want)) {
                    var it: Iter = undefined;
                    if (db.dbus_message_iter_init(m, &it) == 0 or db.dbus_message_iter_get_arg_type(&it) != DT.uint32) {
                        db.dbus_message_unref(m);
                        return error.Failed;
                    }
                    var code: u32 = 2;
                    db.dbus_message_iter_get_basic(&it, &code);
                    dbg("portal: resposta {d} para {s}", .{ code, tok });
                    if (code == 0) return m;
                    db.dbus_message_unref(m);
                    return if (code == 1) error.Cancelled else error.Failed;
                }
                db.dbus_message_unref(m);
            }
        }
        return error.Cancelled;
    }

    /// Vai ao valor de `key` nos resultados (a{sv}) de um Response: `val` fica no
    /// conteúdo do variant.
    fn findResult(db: *const DBus, m: *Msg, key: []const u8, val: *Iter) bool {
        var it: Iter = undefined;
        if (db.dbus_message_iter_init(m, &it) == 0) return false;
        if (db.dbus_message_iter_next(&it) == 0 or db.dbus_message_iter_get_arg_type(&it) != DT.array) return false;
        var arr: Iter = undefined;
        db.dbus_message_iter_recurse(&it, &arr);
        while (db.dbus_message_iter_get_arg_type(&arr) == DT.dict_entry) {
            var e: Iter = undefined;
            db.dbus_message_iter_recurse(&arr, &e);
            var k: [*:0]const u8 = "";
            if (db.dbus_message_iter_get_arg_type(&e) == DT.string) db.dbus_message_iter_get_basic(&e, @ptrCast(&k));
            if (std.mem.eql(u8, std.mem.span(k), key) and db.dbus_message_iter_next(&e) != 0 and db.dbus_message_iter_get_arg_type(&e) == DT.variant) {
                db.dbus_message_iter_recurse(&e, val);
                return true;
            }
            if (db.dbus_message_iter_next(&arr) == 0) break;
        }
        return false;
    }

    fn createSession(p: *Portal, db: *const DBus, stop: *const std.atomic.Value(bool)) Error!void {
        const m = db.dbus_message_new_method_call(bus, obj, iface, "CreateSession") orelse return error.Failed;
        defer db.dbus_message_unref(m);
        var tb: [48]u8 = undefined;
        const tok = p.token(&tb);
        var sb: [48]u8 = undefined;
        const stok = p.token(&sb);
        var args: Iter = undefined;
        var dict: Iter = undefined;
        db.dbus_message_iter_init_append(m, &args);
        openDict(db, &args, &dict);
        const tz: [*:0]const u8 = tok.ptr;
        const sz: [*:0]const u8 = stok.ptr;
        entry(db, &dict, "handle_token", DT.string, "s", @ptrCast(&tz));
        entry(db, &dict, "session_handle_token", DT.string, "s", @ptrCast(&sz));
        _ = db.dbus_message_iter_close_container(&args, &dict);
        db.dbus_message_unref(try p.call(db, m));
        const resp = try p.waitResponse(db, tok, stop);
        defer db.dbus_message_unref(resp);
        var v: Iter = undefined;
        if (!findResult(db, resp, "session_handle", &v)) return error.Failed;
        const vt = db.dbus_message_iter_get_arg_type(&v);
        if (vt != DT.string and vt != DT.object_path) return error.Failed;
        var s: [*:0]const u8 = "";
        db.dbus_message_iter_get_basic(&v, @ptrCast(&s));
        const span = std.mem.span(s);
        if (span.len == 0 or span.len >= p.session.len) return error.Failed;
        @memcpy(p.session[0..span.len], span);
        p.session_len = span.len;
        dbg("portal: sessão aberta", .{});
    }

    fn selectSources(p: *Portal, db: *const DBus, stop: *const std.atomic.Value(bool), cursor: u32) Error!void {
        const m = db.dbus_message_new_method_call(bus, obj, iface, "SelectSources") orelse return error.Failed;
        defer db.dbus_message_unref(m);
        var tb: [48]u8 = undefined;
        const tok = p.token(&tb);
        var pb: [256]u8 = undefined;
        const path: [*:0]const u8 = p.sessionZ(&pb).ptr;
        var args: Iter = undefined;
        var dict: Iter = undefined;
        db.dbus_message_iter_init_append(m, &args);
        _ = db.dbus_message_iter_append_basic(&args, DT.object_path, @ptrCast(&path));
        openDict(db, &args, &dict);
        const tz: [*:0]const u8 = tok.ptr;
        entry(db, &dict, "handle_token", DT.string, "s", @ptrCast(&tz));
        const types: u32 = 1 | 2; // tela ou janela
        entry(db, &dict, "types", DT.uint32, "u", @ptrCast(&types));
        const multiple: u32 = 0;
        entry(db, &dict, "multiple", DT.boolean, "b", @ptrCast(&multiple));
        entry(db, &dict, "cursor_mode", DT.uint32, "u", @ptrCast(&cursor));
        _ = db.dbus_message_iter_close_container(&args, &dict);
        db.dbus_message_unref(try p.call(db, m));
        const resp = try p.waitResponse(db, tok, stop);
        db.dbus_message_unref(resp);
    }

    fn startCast(p: *Portal, db: *const DBus, stop: *const std.atomic.Value(bool)) Error!void {
        const m = db.dbus_message_new_method_call(bus, obj, iface, "Start") orelse return error.Failed;
        defer db.dbus_message_unref(m);
        var tb: [48]u8 = undefined;
        const tok = p.token(&tb);
        var pb: [256]u8 = undefined;
        const path: [*:0]const u8 = p.sessionZ(&pb).ptr;
        const parent: [*:0]const u8 = "";
        var args: Iter = undefined;
        var dict: Iter = undefined;
        db.dbus_message_iter_init_append(m, &args);
        _ = db.dbus_message_iter_append_basic(&args, DT.object_path, @ptrCast(&path));
        _ = db.dbus_message_iter_append_basic(&args, DT.string, @ptrCast(&parent));
        openDict(db, &args, &dict);
        const tz: [*:0]const u8 = tok.ptr;
        entry(db, &dict, "handle_token", DT.string, "s", @ptrCast(&tz));
        _ = db.dbus_message_iter_close_container(&args, &dict);
        db.dbus_message_unref(try p.call(db, m));
        const resp = try p.waitResponse(db, tok, stop);
        defer db.dbus_message_unref(resp);
        // streams: a(ua{sv}): o nó do PipeWire do primeiro.
        var v: Iter = undefined;
        if (!findResult(db, resp, "streams", &v) or db.dbus_message_iter_get_arg_type(&v) != DT.array) return error.Failed;
        var arr: Iter = undefined;
        db.dbus_message_iter_recurse(&v, &arr);
        if (db.dbus_message_iter_get_arg_type(&arr) != DT.@"struct") return error.Failed;
        var st: Iter = undefined;
        db.dbus_message_iter_recurse(&arr, &st);
        if (db.dbus_message_iter_get_arg_type(&st) != DT.uint32) return error.Failed;
        db.dbus_message_iter_get_basic(&st, &p.node);
        dbg("portal: nó {d}", .{p.node});
    }

    fn openRemote(p: *Portal, db: *const DBus) Error!void {
        const m = db.dbus_message_new_method_call(bus, obj, iface, "OpenPipeWireRemote") orelse return error.Failed;
        defer db.dbus_message_unref(m);
        var pb: [256]u8 = undefined;
        const path: [*:0]const u8 = p.sessionZ(&pb).ptr;
        var args: Iter = undefined;
        var dict: Iter = undefined;
        db.dbus_message_iter_init_append(m, &args);
        _ = db.dbus_message_iter_append_basic(&args, DT.object_path, @ptrCast(&path));
        openDict(db, &args, &dict);
        _ = db.dbus_message_iter_close_container(&args, &dict);
        const reply = try p.call(db, m);
        defer db.dbus_message_unref(reply);
        var it: Iter = undefined;
        if (db.dbus_message_iter_init(reply, &it) == 0 or db.dbus_message_iter_get_arg_type(&it) != DT.unix_fd) return error.Failed;
        db.dbus_message_iter_get_basic(&it, &p.fd);
        if (p.fd < 0) return error.Failed;
    }

    fn connectPw(p: *Portal, pw: *const Pw) Error!void {
        p.loop = pw.pw_thread_loop_new("larper-tela", null) orelse return error.Failed;
        p.context = pw.pw_context_new(pw.pw_thread_loop_get_loop(p.loop.?), null, 0) orelse return error.Failed;
        if (pw.pw_thread_loop_start(p.loop.?) < 0) return error.Failed;
        pw.pw_thread_loop_lock(p.loop.?);
        defer pw.pw_thread_loop_unlock(p.loop.?);
        // O PipeWire fica com o fd.
        p.core = pw.pw_context_connect_fd(p.context.?, p.fd, null, 0) orelse return error.Failed;
        p.fd = -1;
        const props = pw.pw_properties_new_string("media.type=Video media.category=Capture media.role=Screen");
        p.stream = pw.pw_stream_new(p.core.?, "larperCord", props) orelse return error.Failed;
        p.events = .{ .state_changed = onState, .param_changed = onParam, .process = onProcess };
        pw.pw_stream_add_listener(p.stream.?, &p.hook, &p.events, p);
        var w: PodWriter = .{};
        enumFormat(&w, p.fps);
        const params = [_]*const anyopaque{@ptrCast(&w.buf)};
        // AUTOCONNECT | MAP_BUFFERS; entrada (0).
        if (pw.pw_stream_connect(p.stream.?, 0, p.node, 1 | 4, &params, 1) < 0) return error.Failed;
    }

    fn onState(data: ?*anyopaque, _: c_int, state: c_int, err: ?[*:0]const u8) callconv(.c) void {
        const p: *Portal = @ptrCast(@alignCast(data.?));
        dbg("pipewire: estado {d}{s}", .{ state, if (err) |e| std.mem.span(e) else "" });
        // Erro (-1) ou desconectado (0) depois de começar: a captura acabou.
        if (state <= 0) {
            p.ended.store(true, .release);
            if (p.cond) |cd| c.SDL_BroadcastCondition(cd);
        }
    }

    fn onParam(data: ?*anyopaque, id: u32, param: ?*const anyopaque) callconv(.c) void {
        const p: *Portal = @ptrCast(@alignCast(data.?));
        if (id != spa.param_format) return;
        const pod_ptr: [*]const u8 = @ptrCast(param orelse return);
        const size = std.mem.readInt(u32, pod_ptr[0..4], .little);
        const neg = parseFormat(pod_ptr[0 .. 8 + @as(usize, @min(size, 4096))]) orelse return;
        dbg("pipewire: formato {d}, {d}x{d}", .{ neg.fmt, neg.w, neg.h });
        c.SDL_LockMutex(p.mutex);
        p.neg = neg;
        c.SDL_UnlockMutex(p.mutex);
        const pw = pwApi() orelse return;
        var w: PodWriter = .{};
        buffersParam(&w);
        const params = [_]*const anyopaque{@ptrCast(&w.buf)};
        _ = pw.pw_stream_update_params(p.stream.?, &params, 1);
    }

    fn onProcess(data: ?*anyopaque) callconv(.c) void {
        const p: *Portal = @ptrCast(@alignCast(data.?));
        const pw = pwApi() orelse return;
        const s = p.stream orelse return;
        // Só o mais novo interessa: os mais velhos voltam direto.
        var newest: ?*PwBuffer = null;
        while (pw.pw_stream_dequeue_buffer(s)) |b| {
            if (newest) |o| _ = pw.pw_stream_queue_buffer(s, o);
            newest = b;
        }
        const b = newest orelse return;
        defer _ = pw.pw_stream_queue_buffer(s, b);
        if (b.buffer.n_datas < 1) return;
        const d0 = &b.buffer.datas[0];
        const px = d0.data orelse return;
        const ch = d0.chunk orelse return;
        if (ch.flags & spa.chunk_corrupted != 0 or ch.size == 0) return;
        c.SDL_LockMutex(p.mutex);
        defer c.SDL_UnlockMutex(p.mutex);
        const neg = p.neg;
        const fmt = pixOf(neg.fmt) orelse return;
        if (neg.w == 0 or neg.h == 0) return;
        const stride: usize = if (ch.stride > 0) @intCast(ch.stride) else neg.w * 4;
        const row = @as(usize, neg.w) * 4;
        if (stride < row) return;
        const need = @as(usize, ch.offset) + stride * (neg.h - 1) + row;
        if (need > d0.maxsize) return;
        p.frame.resize(alloc, row * neg.h) catch return;
        const src = px + ch.offset;
        for (0..neg.h) |y| @memcpy(p.frame.items[y * row ..][0..row], src[y * stride ..][0..row]);
        p.frame_w = neg.w;
        p.frame_h = neg.h;
        p.frame_fmt = fmt;
        p.seq += 1;
        c.SDL_BroadcastCondition(p.cond);
    }

    /// O quadro mais novo, se chegou um depois do último pedido (espera até
    /// `timeout_ms`). Vale até a próxima chamada.
    pub fn next(p: *Portal, timeout_ms: u32) ?video_codec.Image {
        c.SDL_LockMutex(p.mutex);
        defer c.SDL_UnlockMutex(p.mutex);
        if (p.seq == p.taken and !p.ended.load(.acquire)) _ = c.SDL_WaitConditionTimeout(p.cond, p.mutex, @intCast(timeout_ms));
        if (p.seq == p.taken or p.frame_w == 0) return null;
        p.taken = p.seq;
        p.local.resize(alloc, p.frame.items.len) catch return null;
        @memcpy(p.local.items, p.frame.items);
        return .{ .px = p.local.items.ptr, .stride = p.frame_w * 4, .w = p.frame_w, .h = p.frame_h, .fmt = p.frame_fmt };
    }

    pub fn close(p: *Portal) void {
        if (pwApi()) |pw| {
            if (p.loop) |l| pw.pw_thread_loop_lock(l);
            if (p.stream) |s| {
                _ = pw.pw_stream_disconnect(s);
                pw.pw_stream_destroy(s);
            }
            p.stream = null;
            if (p.core) |co| _ = pw.pw_core_disconnect(co);
            p.core = null;
            if (p.loop) |l| pw.pw_thread_loop_unlock(l);
            if (p.loop) |l| pw.pw_thread_loop_stop(l);
            if (p.context) |cx| pw.pw_context_destroy(cx);
            p.context = null;
            if (p.loop) |l| pw.pw_thread_loop_destroy(l);
            p.loop = null;
        }
        if (p.fd >= 0) _ = c.close(p.fd);
        p.fd = -1;
        if (dbusApi()) |db| if (p.conn) |conn| {
            // Fecha a sessão do portal (o ícone de "compartilhando" do sistema some).
            var sb: [256]u8 = undefined;
            if (p.session_len > 0) if (db.dbus_message_new_method_call(bus, p.sessionZ(&sb).ptr, "org.freedesktop.portal.Session", "Close")) |m| {
                var err: Err = .{};
                db.dbus_error_init(&err);
                if (db.dbus_connection_send_with_reply_and_block(conn, m, 2000, &err)) |r| db.dbus_message_unref(r);
                db.dbus_error_free(&err);
                db.dbus_message_unref(m);
            };
            db.dbus_connection_close(conn);
            db.dbus_connection_unref(conn);
            p.conn = null;
        };
        if (p.cond) |cd| c.SDL_DestroyCondition(cd);
        if (p.mutex) |m| c.SDL_DestroyMutex(m);
        p.cond = null;
        p.mutex = null;
        p.frame.deinit(alloc);
        p.local.deinit(alloc);
    }
};

// --- Testes ------------------------------------------------------------------

const t = std.testing;

test "POD: o EnumFormat se lê de volta, com a escolha do formato" {
    var w: PodWriter = .{};
    enumFormat(&w, 30);
    try t.expect(w.len % 8 == 0);
    const neg = parseFormat(w.bytes()).?;
    // Numa escolha, vale o primeiro valor (o padrão).
    try t.expectEqual(spa.BGRx, neg.fmt);
    try t.expectEqual(@as(u32, 1920), neg.w);
    try t.expectEqual(@as(u32, 1080), neg.h);
    // Tamanho do objeto: tudo menos o cabeçalho de 8 bytes.
    try t.expectEqual(@as(u32, @intCast(w.len - 8)), std.mem.readInt(u32, w.buf[0..4], .little));
}

test "POD: Format fixo (valores sem escolha)" {
    var w: PodWriter = .{};
    const at = w.beginObject(spa.object_format, spa.param_format);
    w.prop(spa.format_video_format);
    w.id(spa.RGBA);
    w.prop(spa.format_video_size);
    w.put(8);
    w.put(spa.type_rect);
    w.put(2560);
    w.put(1440);
    w.endObject(at);
    const neg = parseFormat(w.bytes()).?;
    try t.expectEqual(spa.RGBA, neg.fmt);
    try t.expectEqual(@as(u32, 2560), neg.w);
    try t.expectEqual(video_codec.PixFmt.rgba, pixOf(neg.fmt).?);
    try t.expect(parseFormat(&[_]u8{ 1, 2, 3 }) == null);
}
