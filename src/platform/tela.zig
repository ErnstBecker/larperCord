//! A captura da tela para transmitir: de onde vêm os quadros que o codificador
//! lê (net/golive_media.zig).
//!
//!   - Wayland: o portal do sistema (platform/tela_portal.zig), que mostra o
//!     próprio diálogo para escolher tela ou janela;
//!   - X11: o x11grab da libavdevice do FFmpeg, uma tela inteira com o cursor;
//!   - Windows: GDI (BitBlt), uma tela inteira com o cursor;
//!   - `synthetic`: um padrão que se mexe, sem tela nenhuma (a demonstração e o QA).
//!
//! `next` devolve o quadro mais novo e espera até o próximo quando não há; a
//! imagem vale até a próxima chamada. Tudo numa thread só (a do codificador),
//! fora o PipeWire, que entrega na thread dele.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const ffmpeg = @import("ffmpeg.zig");
const video_codec = @import("video_codec.zig");
const portal = if (builtin.os.tag == .linux) @import("tela_portal.zig") else struct {
    pub const Portal = struct {
        pub fn open(_: *@This(), _: u32, _: *const std.atomic.Value(bool)) error{ Missing, NoPortal, Cancelled, Failed }!void {
            return error.Missing;
        }
        pub fn next(_: *@This(), _: u32) ?video_codec.Image {
            return null;
        }
        pub fn close(_: *@This()) void {}
        ended: std.atomic.Value(bool) = .init(true),
    };
    pub fn missing() ?[]const u8 {
        return null;
    }
};

const alloc = std.heap.c_allocator;

pub const Kind = enum(u8) { portal, x11, gdi, synthetic };

/// O que capturar. Tela inteira (x11, gdi): o retângulo dela, em pixels.
pub const Target = struct {
    kind: Kind,
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

/// Como a captura deste sistema funciona: o diálogo do sistema escolhe (Wayland)
/// ou o app lista as telas (X11, Windows).
pub fn native() Kind {
    if (builtin.os.tag == .windows) return .gdi;
    const drv = if (c.SDL_GetCurrentVideoDriver()) |p| std.mem.span(p) else "";
    if (std.mem.eql(u8, drv, "x11")) return .x11;
    if (std.mem.eql(u8, drv, "wayland")) return .portal;
    // Sem janela ainda (testes): pelo ambiente.
    if (c.SDL_getenv("WAYLAND_DISPLAY") != null) return .portal;
    return .x11;
}

/// Uma tela, para escolher no X11 e no Windows.
pub const Screen = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn label(s: *const Screen) []const u8 {
        return s.name[0..s.name_len];
    }
};

pub fn screens(out: []Screen) []Screen {
    var n: c_int = 0;
    const ids = c.SDL_GetDisplays(&n) orelse return out[0..0];
    defer c.SDL_free(ids);
    var k: usize = 0;
    for (ids[0..@intCast(@max(n, 0))]) |id| {
        if (k == out.len) break;
        var r: c.SDL_Rect = undefined;
        if (!c.SDL_GetDisplayBounds(id, &r) or r.w <= 0 or r.h <= 0) continue;
        var s: Screen = .{ .x = r.x, .y = r.y, .w = @intCast(r.w), .h = @intCast(r.h) };
        const nm = if (c.SDL_GetDisplayName(id)) |p| std.mem.span(p) else "";
        const txt = std.fmt.bufPrint(&s.name, "{s} ({d}×{d})", .{ if (nm.len > 0) nm[0..@min(nm.len, 40)] else "?", r.w, r.h }) catch s.name[0..0];
        s.name_len = txt.len;
        out[k] = s;
        k += 1;
    }
    return out[0..k];
}

/// O que falta para capturar deste jeito (null = nada): mostrado ao tentar.
pub fn missing(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .portal => portal.missing(),
        .x11 => if (ffmpeg.get() == null) "FFmpeg" else if (avdevice() == null) "libavdevice (FFmpeg)" else null,
        .gdi, .synthetic => null,
    };
}

pub const Error = error{ Missing, NoPortal, Cancelled, Failed };

pub const Capture = struct {
    target: Target,
    fps: u32,
    backend: union(enum) {
        none,
        portal: *portal.Portal,
        x11: X11,
        gdi: Gdi,
        synthetic: Synthetic,
    } = .none,

    /// Abre a captura. No Wayland, bloqueia enquanto o diálogo do sistema está
    /// aberto; `stop` cancela.
    pub fn open(target: Target, fps: u32, stop: *const std.atomic.Value(bool)) Error!Capture {
        var cap: Capture = .{ .target = target, .fps = fps };
        switch (target.kind) {
            .portal => {
                const p = alloc.create(portal.Portal) catch return error.Failed;
                p.* = .{};
                p.open(fps, stop) catch |e| {
                    p.close();
                    alloc.destroy(p);
                    return e;
                };
                cap.backend = .{ .portal = p };
            },
            .x11 => cap.backend = .{ .x11 = try X11.open(target, fps) },
            .gdi => cap.backend = .{ .gdi = try Gdi.open(target, fps) },
            .synthetic => cap.backend = .{ .synthetic = .{ .fps = fps, .w = if (target.w > 0) target.w else 1280, .h = if (target.h > 0) target.h else 720 } },
        }
        return cap;
    }

    /// O próximo quadro (null: nada novo em `timeout_ms`, a tela está parada).
    pub fn next(cap: *Capture, timeout_ms: u32) ?video_codec.Image {
        return switch (cap.backend) {
            .none => null,
            .portal => |p| p.next(timeout_ms),
            .x11 => |*x| x.next(),
            .gdi => |*g| g.next(),
            .synthetic => |*s| s.next(),
        };
    }

    /// A captura acabou por fora (a pessoa parou pelo sistema).
    pub fn ended(cap: *const Capture) bool {
        return switch (cap.backend) {
            .portal => |p| p.ended.load(.acquire),
            .none => true,
            else => false,
        };
    }

    pub fn close(cap: *Capture) void {
        switch (cap.backend) {
            .none => {},
            .portal => |p| {
                p.close();
                alloc.destroy(p);
            },
            .x11 => |*x| x.close(),
            .gdi => |*g| g.close(),
            .synthetic => |*s| s.close(),
        }
        cap.backend = .none;
    }
};

// --- Ritmo -------------------------------------------------------------------

/// Dorme até o próximo quadro (a captura que não espera sozinha).
const Pace = struct {
    next_ns: u64 = 0,

    fn wait(p: *Pace, fps: u32) void {
        const step: u64 = 1_000_000_000 / @max(fps, 1);
        const now = c.SDL_GetTicksNS();
        if (p.next_ns == 0 or now > p.next_ns + step * 4) p.next_ns = now;
        if (p.next_ns > now) c.SDL_DelayNS(p.next_ns - now);
        p.next_ns += step;
    }
};

// --- Sintética ---------------------------------------------------------------

/// Um padrão que se mexe: gradiente, uma faixa que anda e um quadrado que quica.
/// Barata e previsível (o QA confere as cores).
pub const Synthetic = struct {
    fps: u32,
    w: u32,
    h: u32,
    px: std.ArrayList(u8) = .empty,
    n: u32 = 0,
    pace: Pace = .{},

    fn next(s: *Synthetic) ?video_codec.Image {
        s.pace.wait(s.fps);
        s.px.resize(alloc, @as(usize, s.w) * s.h * 4) catch return null;
        draw(s.px.items, s.w, s.h, s.n);
        s.n += 1;
        return .{ .px = s.px.items.ptr, .stride = s.w * 4, .w = s.w, .h = s.h, .fmt = .bgrx };
    }

    fn close(s: *Synthetic) void {
        s.px.deinit(alloc);
    }

    /// O quadro `n` do padrão (BGRx).
    pub fn draw(px: []u8, w: u32, h: u32, n: u32) void {
        const bar = (n * 8) % w;
        const bw = w / 10;
        const sq = h / 5;
        const period = (w - sq) * 2;
        const sx0 = (n * 6) % period;
        const sx = if (sx0 < w - sq) sx0 else period - sx0;
        const sy = h / 2 - sq / 2;
        for (0..h) |y| {
            const row = px[y * w * 4 ..][0 .. w * 4];
            const gy: u8 = @intCast(y * 160 / h);
            for (0..w) |x| {
                var b: u8 = @intCast(60 + x * 120 / w);
                var g: u8 = gy;
                var r: u8 = 40;
                if (x >= bar and x < bar + bw) {
                    r = 230;
                    g = 230;
                    b = 230;
                }
                if (x >= sx and x < sx + sq and y >= sy and y < sy + sq) {
                    r = 237;
                    g = 66;
                    b = 69;
                }
                row[x * 4 + 0] = b;
                row[x * 4 + 1] = g;
                row[x * 4 + 2] = r;
                row[x * 4 + 3] = 255;
            }
        }
    }
};

// --- X11 (x11grab) -------------------------------------------------------------

const AvDevice = struct {
    avdevice_register_all: *const fn () callconv(.c) void,
};
var avd: ?AvDevice = null;
var avd_tried = false;

fn avdevice() ?*const AvDevice {
    if (!avd_tried) {
        avd_tried = true;
        if (ffmpeg.get() == null) return null;
        var nb: [48]u8 = undefined;
        const lavf = ffmpeg.loadedLavf();
        const name = std.fmt.bufPrintSentinel(&nb, "libavdevice.so.{d}", .{lavf}, 0) catch return null;
        // Da mesma pasta do FFmpeg escolhido, se foi uma pasta; senão pelo nome.
        var pb: [640]u8 = undefined;
        const dir = ffmpeg.loadedDir();
        const path = if (dir.len > 0) (std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, name }, 0) catch name) else name;
        const lib = c.SDL_LoadObject(path.ptr) orelse return null;
        const f = c.SDL_LoadFunction(lib, "avdevice_register_all") orelse return null;
        avd = .{ .avdevice_register_all = @ptrCast(f) };
        avd.?.avdevice_register_all();
    }
    return if (avd) |*a| a else null;
}

const X11 = struct {
    api: *const ffmpeg.Api,
    fmt: ?*ffmpeg.FormatCtx = null,
    pkt: ?*ffmpeg.Packet = null,
    have: bool = false,
    w: u32,
    h: u32,

    fn open(target: Target, fps: u32) Error!X11 {
        const a = ffmpeg.get() orelse return error.Missing;
        _ = avdevice() orelse return error.Missing;
        const input = a.av_find_input_format("x11grab") orelse return error.Missing;
        var x: X11 = .{ .api = a, .w = target.w & ~@as(u32, 1), .h = target.h & ~@as(u32, 1) };
        errdefer x.close();
        x.pkt = a.av_packet_alloc() orelse return error.Failed;
        var opts: ?*anyopaque = null;
        defer a.av_dict_free(&opts);
        var b: [64]u8 = undefined;
        _ = a.av_dict_set(&opts, "video_size", (std.fmt.bufPrintSentinel(&b, "{d}x{d}", .{ x.w, x.h }, 0) catch return error.Failed).ptr, 0);
        _ = a.av_dict_set(&opts, "framerate", (std.fmt.bufPrintSentinel(&b, "{d}", .{fps}, 0) catch return error.Failed).ptr, 0);
        _ = a.av_dict_set(&opts, "draw_mouse", "1", 0);
        const disp = if (c.SDL_getenv("DISPLAY")) |d| std.mem.span(d) else ":0";
        var ub: [128]u8 = undefined;
        const url = std.fmt.bufPrintSentinel(&ub, "{s}+{d},{d}", .{ disp, target.x, target.y }, 0) catch return error.Failed;
        var fmt: ?*ffmpeg.FormatCtx = null;
        if (a.avformat_open_input(&fmt, url.ptr, input, @ptrCast(&opts)) < 0) return error.Failed;
        x.fmt = fmt;
        return x;
    }

    fn next(x: *X11) ?video_codec.Image {
        const a = x.api;
        const p = x.pkt orelse return null;
        if (x.have) a.av_packet_unref(p);
        x.have = false;
        if (a.av_read_frame(x.fmt.?, p) < 0) return null;
        x.have = true;
        const data = ffmpeg.packetData(p);
        // bgr0 cru, linha colada na outra.
        if (data.len < @as(usize, x.w) * x.h * 4) return null;
        return .{ .px = data.ptr, .stride = x.w * 4, .w = x.w, .h = x.h, .fmt = .bgrx };
    }

    fn close(x: *X11) void {
        const a = x.api;
        if (x.have) if (x.pkt) |p| a.av_packet_unref(p);
        if (x.pkt != null) a.av_packet_free(&x.pkt);
        if (x.fmt != null) a.avformat_close_input(&x.fmt);
    }
};

// --- Windows (GDI) -------------------------------------------------------------

const Gdi = if (builtin.os.tag == .windows) struct {
    screen: c.HDC = null,
    mem: c.HDC = null,
    bmp: c.HBITMAP = null,
    old: c.HGDIOBJ = null,
    bits: ?[*]u8 = null,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    fps: u32,
    pace: Pace = .{},

    fn open(target: Target, fps: u32) Error!@This() {
        var g: @This() = .{ .x = target.x, .y = target.y, .w = target.w & ~@as(u32, 1), .h = target.h & ~@as(u32, 1), .fps = fps };
        errdefer g.close();
        g.screen = c.GetDC(null) orelse return error.Failed;
        g.mem = c.CreateCompatibleDC(g.screen) orelse return error.Failed;
        var bi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
        bi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        bi.bmiHeader.biWidth = @intCast(g.w);
        bi.bmiHeader.biHeight = -@as(i32, @intCast(g.h)); // de cima para baixo
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = c.BI_RGB;
        var bits: ?*anyopaque = null;
        g.bmp = c.CreateDIBSection(g.mem, &bi, c.DIB_RGB_COLORS, &bits, null, 0) orelse return error.Failed;
        g.bits = @ptrCast(bits orelse return error.Failed);
        g.old = c.SelectObject(g.mem, g.bmp);
        return g;
    }

    fn next(g: *@This()) ?video_codec.Image {
        g.pace.wait(g.fps);
        if (c.BitBlt(g.mem, 0, 0, @intCast(g.w), @intCast(g.h), g.screen, g.x, g.y, c.SRCCOPY | c.CAPTUREBLT) == 0) return null;
        // O cursor não vem no BitBlt: desenha por cima.
        var ci: c.CURSORINFO = std.mem.zeroes(c.CURSORINFO);
        ci.cbSize = @sizeOf(c.CURSORINFO);
        if (c.GetCursorInfo(&ci) != 0 and ci.flags & c.CURSOR_SHOWING != 0) {
            var ii: c.ICONINFO = undefined;
            if (c.GetIconInfo(ci.hCursor, &ii) != 0) {
                const cx = ci.ptScreenPos.x - @as(i32, @intCast(ii.xHotspot)) - g.x;
                const cy = ci.ptScreenPos.y - @as(i32, @intCast(ii.yHotspot)) - g.y;
                _ = c.DrawIconEx(g.mem, cx, cy, ci.hCursor, 0, 0, 0, null, c.DI_NORMAL);
                if (ii.hbmMask) |m| _ = c.DeleteObject(m);
                if (ii.hbmColor) |m| _ = c.DeleteObject(m);
            }
        }
        return .{ .px = g.bits.?, .stride = g.w * 4, .w = g.w, .h = g.h, .fmt = .bgrx };
    }

    fn close(g: *@This()) void {
        if (g.old != null) _ = c.SelectObject(g.mem, g.old);
        if (g.bmp != null) _ = c.DeleteObject(g.bmp);
        if (g.mem != null) _ = c.DeleteDC(g.mem);
        if (g.screen != null) _ = c.ReleaseDC(null, g.screen);
        g.* = .{ .x = 0, .y = 0, .w = 0, .h = 0, .fps = 0 };
    }
} else struct {
    fn open(_: Target, _: u32) Error!@This() {
        return error.Missing;
    }
    fn next(_: *@This()) ?video_codec.Image {
        return null;
    }
    fn close(_: *@This()) void {}
};

test "padrão sintético: o quadrado anda e as cores ficam no lugar" {
    const w = 64;
    const h = 40;
    var a: [w * h * 4]u8 = undefined;
    var b: [w * h * 4]u8 = undefined;
    Synthetic.draw(&a, w, h, 0);
    Synthetic.draw(&b, w, h, 3);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    // O alfa (x) é sempre 255.
    for (0..w * h) |i| try std.testing.expectEqual(@as(u8, 255), a[i * 4 + 3]);
}
