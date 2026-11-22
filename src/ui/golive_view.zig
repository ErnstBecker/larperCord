//! Transmissão de tela na interface:
//!
//!   - o painel "Compartilhar a tela" (o popup `golive`, aberto pelo botão da barra
//!     da call): o que transmitir (no X11 e no Windows, qual tela; no Wayland o
//!     sistema pergunta) e em que qualidade;
//!   - o palco: a transmissão que se está assistindo, grande, em cima dos quadros
//!     da call, com quem é, o selo AO VIVO, "tela cheia" e "parar de assistir";
//!   - a prévia da nossa própria tela, no nosso quadro, enquanto transmitimos.
//!
//! As imagens chegam das threads de net/golive_media.zig e sobem para uma
//! textura só quando mudam (o quadro do app acorda para isso). Nada anima sozinho.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const w = @import("widgets.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons.zig");
const popup = @import("popup.zig");
const forum = @import("forum.zig");
const golive = @import("../core/golive.zig");
const golive_media = @import("../net/golive_media.zig");
const tela = @import("../platform/tela.zig");
const video_codec = @import("../platform/video_codec.zig");
const ffmpeg = @import("../platform/ffmpeg.zig");
const types = @import("../core/types.zig");
const ChannelState = @import("../core/store.zig").ChannelState;
const Id = types.Id;

const alloc = std.heap.c_allocator;

// --- Texturas ----------------------------------------------------------------

const Tex = struct {
    tex: ?*c.SDL_Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    pic: golive_media.Picture = .{},

    fn upload(t: *Tex, renderer: *c.SDL_Renderer) void {
        const p = &t.pic;
        if (p.w == 0 or p.h == 0) return;
        if (t.tex == null or t.w != p.w or t.h != p.h) {
            if (t.tex) |x| c.SDL_DestroyTexture(x);
            t.tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, @intCast(p.w), @intCast(p.h));
            if (t.tex) |x| _ = c.SDL_SetTextureScaleMode(x, c.SDL_SCALEMODE_LINEAR);
            t.w = p.w;
            t.h = p.h;
        }
        if (t.tex) |x| _ = c.SDL_UpdateTexture(x, null, p.px.items.ptr, @intCast(p.w * 4));
        changed = true;
    }

    fn drop(t: *Tex) void {
        if (t.tex) |x| c.SDL_DestroyTexture(x);
        t.pic.px.clearAndFree(alloc);
        t.* = .{};
    }

    /// A imagem inteira cabendo em `r` (faixas pretas se precisar).
    fn draw(t: *const Tex, dl: *c.ImDrawList, r: d.Rect, radius: f32, alpha: f32) d.Rect {
        const x = t.tex orelse return r;
        const vw: f32 = @floatFromInt(t.w);
        const vh: f32 = @floatFromInt(t.h);
        const k = @min(r.w / vw, r.h / vh);
        const iw = vw * k;
        const ih = vh * k;
        const ir: d.Rect = .{ .x = @round(r.x + (r.w - iw) / 2), .y = @round(r.y + (r.h - ih) / 2), .w = @round(iw), .h = @round(ih) };
        const ref: c.ImTextureRef = .{ ._TexData = null, ._TexID = @intFromPtr(x) };
        c.ImDrawList_AddImageRounded(dl, ref, d.v(ir.x, ir.y), d.v(ir.right(), ir.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha), radius, 0);
        return ir;
    }
};

var watch_tex: Tex = .{};
var preview_tex: Tex = .{};
var changed = false;

/// Uma textura recebeu imagem nova: o desenho é o mesmo, a imagem mudou.
pub fn takeChanged() bool {
    defer changed = false;
    return changed;
}

/// Fim do quadro: a próxima imagem pode acordar o app de novo.
pub fn endFrame() void {
    golive_media.drawn();
}

/// Paramos de assistir ou de transmitir: as texturas saem da memória.
pub fn dropWatch() void {
    watch_tex.drop();
}

pub fn dropPreview() void {
    preview_tex.drop();
}

fn watchTex(ctx: *d.Ctx) ?*const Tex {
    if (golive_media.watchPicture(watch_tex.pic.seq, &watch_tex.pic)) watch_tex.upload(ctx.images.renderer);
    return if (watch_tex.tex != null) &watch_tex else null;
}

fn previewTex(ctx: *d.Ctx) ?*const Tex {
    if (golive_media.sharePreview(preview_tex.pic.seq, &preview_tex.pic)) preview_tex.upload(ctx.images.renderer);
    return if (preview_tex.tex != null) &preview_tex else null;
}

// --- A prévia no nosso quadro --------------------------------------------------

/// Transmitindo: a nossa tela como fundo do nosso quadro, escurecida embaixo para
/// o nome continuar legível. true = desenhou.
pub fn tilePreview(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, radius: f32) bool {
    if (ctx.st.golive.share != .live or ctx.pip) return false;
    const t = previewTex(ctx) orelse return false;
    d.rect(dl, r, d.Rgba.black, radius);
    _ = t.draw(dl, r, radius, 0.9);
    d.rect(dl, .{ .x = r.x, .y = r.y + r.h * 0.55, .w = r.w, .h = r.h * 0.45 }, d.Rgba.black.alpha(0.45), radius);
    qa.mark(r, "golive-preview", .{});
    golive_media.drawn();
    return true;
}

// --- O palco -------------------------------------------------------------------

/// A altura do palco numa área `h` (os quadros ficam com o resto, numa faixa).
pub fn stageHeight(ctx: *const d.Ctx, h: f32) f32 {
    if (ctx.st.golive.focus) return h;
    return @max(h - std.math.clamp(h * 0.24, 120, 190), h * 0.6);
}

/// Estamos assistindo alguém desta call?
pub fn watchingHere(ctx: *const d.Ctx, cs: *const ChannelState) bool {
    const uid = ctx.st.golive.watching;
    if (uid == 0 or ctx.pip) return false;
    return ctx.st.voice == cs.info.id;
}

pub fn stage(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, cs: *ChannelState) void {
    stageEx(ctx, dl, r, cs, true);
}

/// `chrome`: o selo, o nome e os botões por cima do vídeo (a versão em texto põe os
/// dela numa linha em cima).
fn stageEx(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, cs: *ChannelState, chrome: bool) void {
    const uid = ctx.st.golive.watching;
    const radius: f32 = @max(ctx.th.radius, 8);
    d.rect(dl, r, d.Rgba.black, radius);
    qa.mark(r, "golive-stage", .{});
    const state = golive_media.watchState();
    const t = watchTex(ctx);
    if (t) |tx| {
        const ir = tx.draw(dl, r, radius, if (state == .ended) 0.45 else 1);
        qa.mark(ir, "golive-video", .{});
    }
    golive_media.drawn();
    // O que está acontecendo, no meio, enquanto não há imagem (ou acabou).
    const msg: ?[]const u8 = switch (state) {
        .connecting, .idle => if (t == null) i18n.tr("Conectando à transmissão…", "Connecting to the stream…") else null,
        .waiting => if (t == null) i18n.tr("Esperando a imagem…", "Waiting for the picture…") else null,
        .ended => i18n.tr("A transmissão acabou", "The stream ended"),
        .failed => i18n.tr("Não deu para mostrar esta transmissão (precisa do FFmpeg)", "Couldn't show this stream (needs FFmpeg)"),
        .playing => null,
    };
    if (msg) |m| {
        const f = ctx.ui.get(.medium);
        const mw = d.width(f, 15, m);
        d.text(dl, f, 15, r.x + (r.w - mw) / 2, r.y + r.h / 2 - 8, d.Rgba.white.alpha(0.85), m);
        qa.mark(.{ .x = r.x + (r.w - mw) / 2, .y = r.y + r.h / 2 - 10, .w = mw, .h = 20 }, "golive-status", .{});
    }

    // Clique duplo no vídeo alterna a tela cheia.
    if (ctx.hovering(r) and c.ImGui_IsMouseDoubleClicked(0)) ctx.st.golive.focus = !ctx.st.golive.focus;
    if (!chrome) return;
    // Em cima: quem transmite e o selo; à direita, tela cheia e parar de assistir.
    const name = ctx.store.nameIn(cs.info.guild, uid) orelse "?";
    const bf = ctx.ui.get(.bold);
    const lt = i18n.tr("AO VIVO", "LIVE");
    const lr: d.Rect = .{ .x = r.x + 12, .y = r.y + 12, .w = d.width(bf, 11, lt) + 12, .h = 20 };
    d.rect(dl, lr, ctx.col(.danger), 5);
    d.text(dl, bf, 11, lr.x + 6, d.centerY(lr, 11), d.Rgba.white, lt);
    const nf = ctx.ui.get(.semibold);
    const nw = @min(d.width(nf, 14, name), r.w * 0.5);
    const nr: d.Rect = .{ .x = lr.right() + 8, .y = lr.y - 2, .w = nw + 16, .h = 24 };
    d.rect(dl, nr, d.Rgba.black.alpha(0.55), 6);
    _ = d.textClipped(dl, nf, 14, nr.x + 8, d.centerY(nr, 14), d.Rgba.white, name, nw);
    qa.mark(nr, "golive-stage-name:{d}", .{uid});

    const bh: f32 = 30;
    var bx = r.right() - 12;
    const by = r.y + 10;
    // Parar de assistir.
    {
        const label = i18n.tr("Parar de assistir", "Stop watching");
        const bw = d.width(ctx.ui.get(.medium), 13, label) + 24;
        bx -= bw;
        const br: d.Rect = .{ .x = bx, .y = by, .w = bw, .h = bh };
        const hb = d.hit(ctx, 8980, br);
        qa.mark(br, "golive-unwatch", .{});
        d.rect(dl, br, if (hb.hovered) ctx.col(.danger) else d.Rgba.black.alpha(0.6), 7);
        d.text(dl, ctx.ui.get(.medium), 13, br.x + 12, d.centerY(br, 13), d.Rgba.white, label);
        if (hb.clicked) ctx.act(.golive_unwatch);
    }
    // Tela cheia (só o palco, sem os quadros; Esc volta).
    {
        bx -= bh + 8;
        const br: d.Rect = .{ .x = bx, .y = by, .w = bh, .h = bh };
        const hb = d.hit(ctx, 8981, br);
        qa.mark(br, "golive-focus", .{});
        d.rect(dl, br, if (hb.hovered) d.Rgba.black.alpha(0.8) else d.Rgba.black.alpha(0.6), 7);
        icons.expand(dl, br.x + bh / 2, br.y + bh / 2, d.Rgba.white.u());
        d.tip(ctx, br, if (ctx.st.golive.focus) i18n.tr("Mostrar a call (Esc)", "Show the call (Esc)") else i18n.tr("Só a transmissão", "Stream only"), hb.hovered);
        if (hb.clicked) ctx.st.golive.focus = !ctx.st.golive.focus;
    }
}

/// A versão em texto (temas de terminal): uma linha com quem e o que fazer, em
/// cima do palco.
pub fn stageTty(ctx: *d.Ctx, dl: *c.ImDrawList, font: *c.ImFont, fs: f32, r: d.Rect, cs: *ChannelState) f32 {
    const uid = ctx.st.golive.watching;
    const name = ctx.store.nameIn(cs.info.guild, uid) orelse "?";
    var buf: [160]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{s} {s}", .{ i18n.tr("assistindo", "watching"), name }) catch name;
    const h = fs + 10;
    d.text(dl, font, fs, r.x + 8, r.y + 5, ctx.col(.danger), t);
    const label = i18n.tr("[parar]", "[stop]");
    const lw = d.width(font, fs, label) + 8;
    const br: d.Rect = .{ .x = r.x + 16 + d.width(font, fs, t), .y = r.y, .w = lw, .h = h };
    const hb = d.hit(ctx, 8980, br);
    qa.mark(br, "golive-unwatch", .{});
    if (hb.hovered) d.rect(dl, br, ctx.col(.hover), 0);
    d.text(dl, font, fs, br.x + 4, r.y + 5, ctx.col(.accent), label);
    if (hb.clicked) ctx.act(.golive_unwatch);
    // Só a transmissão (os quadros somem; Esc volta).
    const fl = if (ctx.st.golive.focus) i18n.tr("[mostrar a call]", "[show call]") else i18n.tr("[só a tela]", "[stream only]");
    const fr: d.Rect = .{ .x = br.right() + 8, .y = r.y, .w = d.width(font, fs, fl) + 8, .h = h };
    const fh = d.hit(ctx, 8981, fr);
    qa.mark(fr, "golive-focus", .{});
    if (fh.hovered) d.rect(dl, fr, ctx.col(.hover), 0);
    d.text(dl, font, fs, fr.x + 4, r.y + 5, ctx.col(.muted), fl);
    if (fh.clicked) ctx.st.golive.focus = !ctx.st.golive.focus;
    const vr: d.Rect = .{ .x = r.x, .y = r.y + h, .w = r.w, .h = r.h - h };
    stageEx(ctx, dl, vr, cs, false);
    qa.mark(nameRect(r, h), "golive-stage-name:{d}", .{uid});
    return h;
}

fn nameRect(r: d.Rect, h: f32) d.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w / 2, .h = h };
}

// --- O painel ------------------------------------------------------------------

const qualities = [_]golive.Quality{ .p720_30, .p1080_30, .p720_60, .p480_15 };

pub fn qualityAt(i: u8) golive.Quality {
    return qualities[@min(i, qualities.len - 1)];
}

/// O que falta para transmitir daqui (null = nada).
fn missingText(buf: []u8) ?[]const u8 {
    if (ffmpeg.get() == null) return i18n.tr("Precisa do FFmpeg (Configurações → Chat → Vídeos).", "Needs FFmpeg (Settings → Chat → Videos).");
    if (!video_codec.canEncode(.h264)) return i18n.tr("O FFmpeg daqui não tem codificador H.264 (libx264, NVENC, AMF, Quick Sync…).", "This FFmpeg has no H.264 encoder (libx264, NVENC, AMF, Quick Sync…).");
    if (tela.missing(tela.native())) |what| return i18n.fmt(buf, "Falta {s} para capturar a tela.", "{s} is missing to capture the screen.", .{what});
    return null;
}

fn radioRow(ctx: *d.Ctx, dl: *c.ImDrawList, id: usize, r: d.Rect, on: bool, label: []const u8, sub: []const u8, mark: []const u8) bool {
    const hb = d.hit(ctx, id, r);
    qa.mark(r, "{s}", .{mark});
    if (on) d.rect(dl, r, ctx.col(.accent).alpha(0.14), 8) else if (hb.hovered) d.rect(dl, r, ctx.col(.hover), 8);
    const cx = r.x + 16;
    const cy = r.y + r.h / 2;
    c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 7, (if (on) ctx.col(.accent) else ctx.col(.muted)).u(), 0, 1.6, 0);
    if (on) c.ImDrawList_AddCircleFilled(dl, d.v(cx, cy), 3.6, ctx.col(.accent).u(), 0);
    const f = ctx.ui.get(.medium);
    _ = d.textClipped(dl, f, 13, r.x + 32, d.centerY(r, 13) - (if (sub.len > 0) @as(f32, 7) else 0), ctx.col(.text), label, r.w - 40);
    if (sub.len > 0) _ = d.textClipped(dl, ctx.ui.get(.regular), 11, r.x + 32, d.centerY(r, 11) + 8, ctx.col(.muted), sub, r.w - 40);
    return hb.clicked;
}

/// "Compartilhar a tela": o que e em que qualidade.
pub fn picker(ctx: *d.Ctx, x: f32, y: f32) void {
    const gl = &ctx.st.golive;
    const kind = tela.native();
    var scr_buf: [8]tela.Screen = undefined;
    const scrs: []tela.Screen = if (kind == .portal) scr_buf[0..0] else tela.screens(&scr_buf);
    var mb: [160]u8 = undefined;
    const missing = missingText(&mb);
    const wd: f32 = 340;
    const row: f32 = 38;
    const src_rows: f32 = if (kind == .portal) 1 else @floatFromInt(@max(scrs.len, 1));
    // Cabeçalho, "O QUE", as fontes, "QUALIDADE", as qualidades, o aviso e o botão.
    const h: f32 = 54 + 22 + src_rows * row + 8 + 22 + @as(f32, qualities.len) * row + 8 + (if (missing != null) @as(f32, 44) else 0) + 52;
    const r = popup.fit(ctx, x, y - h, wd, h);
    const dl = popup.beginWindow("##golive-picker", r);
    defer c.ImGui_End();
    qa.mark(r, "golive-picker", .{});
    d.shadow(dl, r, 14, 22, ctx.col(.shadow).alpha(0.55));
    d.rect(dl, r, ctx.col(.elevated), 14);
    d.border(dl, r, ctx.col(.border), 14, 1);
    d.rect(dl, .{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = 2.5 }, ctx.col(.accent).alpha(0.85), 4);
    d.text(dl, ctx.ui.get(.bold), 15, r.x + 16, r.y + 14, ctx.col(.text), i18n.tr("Compartilhar a tela", "Share your screen"));
    d.text(dl, ctx.ui.get(.regular), 11, r.x + 16, r.y + 34, ctx.col(.muted), i18n.tr("quem está na call pode assistir", "people in the call can watch"));
    const xr: d.Rect = .{ .x = r.right() - 37, .y = r.y + 10, .w = 28, .h = 28 };
    const xh = d.hit(ctx, 8990, xr);
    qa.mark(xr, "golive-picker-close", .{});
    if (xh.hovered) d.rect(dl, xr, ctx.col(.hover), 7);
    d.line(dl, xr.x + 9, xr.y + 9, xr.x + 19, xr.y + 19, ctx.col(.muted), 1.8);
    d.line(dl, xr.x + 19, xr.y + 9, xr.x + 9, xr.y + 19, ctx.col(.muted), 1.8);
    if (xh.clicked) return popup.close(ctx);

    var yy = r.y + 54;
    const sec = ctx.ui.get(.semibold);
    d.text(dl, sec, 11, r.x + 16, yy, ctx.col(.faint), i18n.tr("O QUE", "WHAT"));
    yy += 22;
    if (kind == .portal) {
        const rr: d.Rect = .{ .x = r.x + 8, .y = yy, .w = r.w - 16, .h = row - 2 };
        _ = radioRow(ctx, dl, 8991, rr, true, i18n.tr("Uma tela ou uma janela", "A screen or a window"), i18n.tr("o sistema pergunta qual", "the system asks which one"), "golive-src-portal");
        yy += row;
    } else if (scrs.len == 0) {
        d.text(dl, ctx.ui.get(.regular), 12, r.x + 16, yy + 10, ctx.col(.muted), i18n.tr("Nenhuma tela encontrada", "No screen found"));
        yy += row;
    } else for (scrs, 0..) |*sc, i| {
        const rr: d.Rect = .{ .x = r.x + 8, .y = yy, .w = r.w - 16, .h = row - 2 };
        var lb: [96]u8 = undefined;
        const label = i18n.fmt(&lb, "Tela {d}", "Screen {d}", .{i + 1});
        var mk: [32]u8 = undefined;
        if (radioRow(ctx, dl, 8992 + i, rr, gl.pick_screen == i, label, sc.label(), std.fmt.bufPrint(&mk, "golive-src:{d}", .{i}) catch "golive-src")) gl.pick_screen = @intCast(i);
        yy += row;
    }
    yy += 8;
    d.text(dl, sec, 11, r.x + 16, yy, ctx.col(.faint), i18n.tr("QUALIDADE", "QUALITY"));
    yy += 22;
    for (qualities, 0..) |q, i| {
        const rr: d.Rect = .{ .x = r.x + 8, .y = yy, .w = r.w - 16, .h = row - 2 };
        var sb: [64]u8 = undefined;
        const sub = i18n.fmt(&sb, "até {d} kbit/s", "up to {d} kbit/s", .{q.kbps()});
        var mk: [32]u8 = undefined;
        if (radioRow(ctx, dl, 9000 + i, rr, gl.pick_quality == i, q.label(), sub, std.fmt.bufPrint(&mk, "golive-quality:{d}", .{i}) catch "golive-quality")) gl.pick_quality = @intCast(i);
        yy += row;
    }
    yy += 8;
    if (missing) |m| {
        const mr: d.Rect = .{ .x = r.x + 12, .y = yy, .w = r.w - 24, .h = 38 };
        d.rect(dl, mr, ctx.col(.danger).alpha(0.14), 8);
        _ = d.textClipped(dl, ctx.ui.get(.regular), 11.5, mr.x + 10, d.centerY(mr, 11.5), ctx.col(.text), m, mr.w - 20);
        qa.mark(mr, "golive-missing", .{});
        d.tip(ctx, mr, m, ctx.hovering(mr));
        yy += 44;
    }
    const label = i18n.tr("Transmitir", "Go Live");
    const bw = d.width(ctx.ui.get(.semibold), 13.5, label) + 36;
    const br: d.Rect = .{ .x = r.right() - bw - 14, .y = r.bottom() - 46, .w = bw, .h = 34 };
    qa.mark(br, "golive-go", .{});
    const can = missing == null and (kind == .portal or scrs.len > 0 or qa.compiled);
    if (forum.primary(ctx, dl, ctx.ui, 9010, br, label, can) and can) {
        popup.close(ctx);
        ctx.act(.{ .golive_share = .{ .screen = gl.pick_screen, .quality = gl.pick_quality } });
    }
}
