//! As peças com que a janela do Inspetor é desenhada: a paleta (no estilo das
//! ferramentas de desenvolvedor dos navegadores, clara ou escura conforme o modo do
//! tema, com o destaque do tema), botões de barra, abas, fichas de filtro, campo de
//! busca, divisória arrastável, listas longas desenhadas só na parte visível e linhas
//! de texto colorido (a árvore de elementos e o JSON).
const std = @import("std");
const c = @import("c");
const d = @import("../ui/draw.zig");
const icons = @import("../ui/icons.zig");

pub const Rgba = d.Rgba;
pub const Rect = d.Rect;

pub const Pal = struct {
    bg: Rgba,
    panel: Rgba,
    toolbar: Rgba,
    line: Rgba,
    text: Rgba,
    dim: Rgba,
    faint: Rgba,
    accent: Rgba,
    sel: Rgba,
    hover: Rgba,
    input: Rgba,
    // Sintaxe: marcas, atributos, valores, textos, números, chaves do JSON.
    tag: Rgba,
    attr: Rgba,
    value: Rgba,
    str: Rgba,
    num: Rgba,
    key: Rgba,
    ok: Rgba,
    warn: Rgba,
    err: Rgba,
    info: Rgba,
    warn_bg: Rgba,
    err_bg: Rgba,
    sent_bg: Rgba,
    // Destaque do elemento na tela (conteúdo, borda, o pedaço do layout).
    hl_fill: Rgba,
    hl_line: Rgba,
    hl_scope: Rgba,
};

pub var pal: Pal = dark(Rgba.hex(0x8AB4F8));

fn dark(accent: Rgba) Pal {
    return .{
        .bg = Rgba.hex(0x202124),
        .panel = Rgba.hex(0x242528),
        .toolbar = Rgba.hex(0x292A2D),
        .line = Rgba.hex(0x3C4043),
        .text = Rgba.hex(0xE8EAED),
        .dim = Rgba.hex(0x9AA0A6),
        .faint = Rgba.hex(0x6E7378),
        .accent = accent,
        .sel = accent.alpha(0.22),
        .hover = Rgba.hex(0xFFFFFF).alpha(0.06),
        .input = Rgba.hex(0x1A1B1E),
        .tag = Rgba.hex(0x5DB0D7),
        .attr = Rgba.hex(0x9BBBDC),
        .value = Rgba.hex(0xF29766),
        .str = Rgba.hex(0xF28B54),
        .num = Rgba.hex(0x9980FF),
        .key = Rgba.hex(0x7CACF8),
        .ok = Rgba.hex(0x81C995),
        .warn = Rgba.hex(0xFDD663),
        .err = Rgba.hex(0xF28B82),
        .info = Rgba.hex(0x8AB4F8),
        .warn_bg = Rgba.hex(0x413C26),
        .err_bg = Rgba.hex(0x4E3534),
        .sent_bg = Rgba.hex(0x1E3A2A),
        .hl_fill = Rgba.hex(0x6FA8DC).alpha(0.38),
        .hl_line = Rgba.hex(0x6FA8DC),
        .hl_scope = Rgba.hex(0xC58AF9),
    };
}

fn light(accent: Rgba) Pal {
    return .{
        .bg = Rgba.hex(0xFFFFFF),
        .panel = Rgba.hex(0xFAFAFA),
        .toolbar = Rgba.hex(0xF1F3F4),
        .line = Rgba.hex(0xD3D5D9),
        .text = Rgba.hex(0x202124),
        .dim = Rgba.hex(0x5F6368),
        .faint = Rgba.hex(0x9AA0A6),
        .accent = accent,
        .sel = accent.alpha(0.16),
        .hover = Rgba.hex(0x000000).alpha(0.05),
        .input = Rgba.hex(0xFFFFFF),
        .tag = Rgba.hex(0x881280),
        .attr = Rgba.hex(0x994500),
        .value = Rgba.hex(0x1A1AA6),
        .str = Rgba.hex(0xC41A16),
        .num = Rgba.hex(0x1C00CF),
        .key = Rgba.hex(0x881391),
        .ok = Rgba.hex(0x188038),
        .warn = Rgba.hex(0xB06000),
        .err = Rgba.hex(0xD93025),
        .info = Rgba.hex(0x1A73E8),
        .warn_bg = Rgba.hex(0xFFFBE5),
        .err_bg = Rgba.hex(0xFCEBEB),
        .sent_bg = Rgba.hex(0xE6F4EA),
        .hl_fill = Rgba.hex(0x6FA8DC).alpha(0.42),
        .hl_line = Rgba.hex(0x1A73E8),
        .hl_scope = Rgba.hex(0x9334E6),
    };
}

/// Uma vez por quadro: a paleta segue o modo do tema e o destaque dele.
pub fn setTheme(light_mode: bool, accent: Rgba) void {
    // Um destaque muito escuro (ou claro demais no modo claro) some no fundo: fica o azul.
    const a = if (light_mode) (if (accent.luminance() > 0.55) Rgba.hex(0x1A73E8) else accent) else (if (accent.luminance() < 0.12) Rgba.hex(0x8AB4F8) else accent);
    pal = if (light_mode) light(a) else dark(a);
}

// --- Contexto de desenho do Inspetor --------------------------------------------

/// O que cada aba recebe: o contexto do app (fontes, mouse, ações) e as fontes do Inspetor.
pub const Ui = struct {
    ctx: *d.Ctx,
    dl: *c.ImDrawList,
    font: *c.ImFont,
    bold: *c.ImFont,
    mono: *c.ImFont,
    mono_bold: *c.ImFont,
    /// Tamanho da letra da interface e do código.
    fs: f32 = 12.5,
    ms: f32 = 12,
    row_h: f32 = 20,

    pub fn mouse(u: *const Ui) c.ImVec2 {
        return u.ctx.mouse;
    }

    pub fn over(u: *const Ui, r: Rect) bool {
        return r.contains(u.ctx.mouse.x, u.ctx.mouse.y) and c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_ChildWindows | c.ImGuiHoveredFlags_AllowWhenBlockedByActiveItem);
    }

    pub fn clicked(u: *const Ui, r: Rect) bool {
        return u.over(r) and c.ImGui_IsMouseClicked(0);
    }

    pub fn rclicked(u: *const Ui, r: Rect) bool {
        return u.over(r) and c.ImGui_IsMouseClicked(1);
    }

    pub fn dclicked(u: *const Ui, r: Rect) bool {
        return u.over(r) and c.ImGui_IsMouseDoubleClicked(0);
    }

    pub fn text(u: *const Ui, x: f32, y: f32, col: Rgba, s: []const u8) f32 {
        d.text(u.dl, u.font, u.fs, x, y, col, s);
        return d.width(u.font, u.fs, s);
    }

    pub fn textB(u: *const Ui, x: f32, y: f32, col: Rgba, s: []const u8) f32 {
        d.text(u.dl, u.bold, u.fs, x, y, col, s);
        return d.width(u.bold, u.fs, s);
    }

    pub fn code(u: *const Ui, x: f32, y: f32, col: Rgba, s: []const u8) f32 {
        d.text(u.dl, u.mono, u.ms, x, y, col, s);
        return d.width(u.mono, u.ms, s);
    }

    pub fn codeW(u: *const Ui, s: []const u8) f32 {
        return d.width(u.mono, u.ms, s);
    }

    pub fn textW(u: *const Ui, s: []const u8) f32 {
        return d.width(u.font, u.fs, s);
    }

    /// Texto que corta com "…" em `max_w`.
    pub fn clip(u: *const Ui, x: f32, y: f32, col: Rgba, s: []const u8, max_w: f32) f32 {
        if (max_w <= 4) return 0;
        return d.textClipped(u.dl, u.font, u.fs, x, y, col, s, max_w);
    }

    pub fn clipCode(u: *const Ui, x: f32, y: f32, col: Rgba, s: []const u8, max_w: f32) f32 {
        if (max_w <= 4) return 0;
        return d.textClipped(u.dl, u.mono, u.ms, x, y, col, s, max_w);
    }

    /// Y do texto centrado numa linha de altura `h` a partir de `y`.
    pub fn mid(u: *const Ui, y: f32, h: f32) f32 {
        return y + (h - u.fs * 1.2) / 2;
    }

    pub fn midCode(u: *const Ui, y: f32, h: f32) f32 {
        return y + (h - u.ms * 1.2) / 2;
    }
};

pub fn rect(u: *const Ui, r: Rect, col: Rgba, rounding: f32) void {
    d.rect(u.dl, r, col, rounding);
}

pub fn hline(u: *const Ui, x0: f32, x1: f32, y: f32, col: Rgba) void {
    d.line(u.dl, x0, y + 0.5, x1, y + 0.5, col, 1);
}

pub fn vline(u: *const Ui, x: f32, y0: f32, y1: f32, col: Rgba) void {
    d.line(u.dl, x + 0.5, y0, x + 0.5, y1, col, 1);
}

// --- Botões, abas e fichas ------------------------------------------------------

pub const Icon = enum { pick, close, clear, record, stop, pause, play, dock_right, dock_bottom, dock_float, copy, download, search, chevron_r, chevron_d, refresh, filter, up, down, eye, gear };

/// Ícones pequenos (~14 px) desenhados com linhas, como os outros do app.
pub fn icon(dl: *c.ImDrawList, which: Icon, cx: f32, cy: f32, col: Rgba) void {
    const u = col.u();
    const L = struct {
        fn ln(l: *c.ImDrawList, x1: f32, y1: f32, x2: f32, y2: f32, cc: u32, th: f32) void {
            c.ImDrawList_AddLineEx(l, d.v(x1, y1), d.v(x2, y2), cc, th, 0);
        }
    };
    switch (which) {
        .pick => {
            // Seta dentro de um quadrado tracejado (o "selecionar elemento").
            c.ImDrawList_AddRectEx(dl, d.v(cx - 7, cy - 7), d.v(cx + 4, cy + 4), u, 1.5, 1.3, 0);
            c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 1, cy - 1), d.v(cx + 7, cy + 2), d.v(cx + 2, cy + 7), u);
        },
        .close => {
            L.ln(dl, cx - 5, cy - 5, cx + 5, cy + 5, u, 1.6);
            L.ln(dl, cx - 5, cy + 5, cx + 5, cy - 5, u, 1.6);
        },
        .clear => {
            c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 6, u, 0, 1.5, 0);
            L.ln(dl, cx - 4, cy + 4, cx + 4, cy - 4, u, 1.5);
        },
        .record => c.ImDrawList_AddCircleFilled(dl, d.v(cx, cy), 5.5, u, 0),
        .stop => c.ImDrawList_AddRectFilledEx(dl, d.v(cx - 5, cy - 5), d.v(cx + 5, cy + 5), u, 1.5, 0),
        .pause => {
            c.ImDrawList_AddRectFilledEx(dl, d.v(cx - 5, cy - 6), d.v(cx - 1.5, cy + 6), u, 1, 0);
            c.ImDrawList_AddRectFilledEx(dl, d.v(cx + 1.5, cy - 6), d.v(cx + 5, cy + 6), u, 1, 0);
        },
        .play => c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 4, cy - 6), d.v(cx + 6, cy), d.v(cx - 4, cy + 6), u),
        .dock_right, .dock_bottom, .dock_float => {
            c.ImDrawList_AddRectEx(dl, d.v(cx - 7, cy - 6), d.v(cx + 7, cy + 6), u, 2, 1.4, 0);
            switch (which) {
                .dock_right => c.ImDrawList_AddRectFilledEx(dl, d.v(cx + 1.5, cy - 6), d.v(cx + 7, cy + 6), u, 1, 0),
                .dock_bottom => c.ImDrawList_AddRectFilledEx(dl, d.v(cx - 7, cy + 1), d.v(cx + 7, cy + 6), u, 1, 0),
                else => c.ImDrawList_AddRectFilledEx(dl, d.v(cx - 3, cy - 2), d.v(cx + 5, cy + 4), u, 1, 0),
            }
        },
        .copy => {
            c.ImDrawList_AddRectEx(dl, d.v(cx - 5, cy - 3), d.v(cx + 3, cy + 6), u, 1.5, 1.3, 0);
            c.ImDrawList_AddRectEx(dl, d.v(cx - 2, cy - 6), d.v(cx + 6, cy + 3), u, 1.5, 1.3, 0);
        },
        .download => {
            L.ln(dl, cx, cy - 6, cx, cy + 3, u, 1.5);
            L.ln(dl, cx - 4, cy - 1, cx, cy + 3, u, 1.5);
            L.ln(dl, cx + 4, cy - 1, cx, cy + 3, u, 1.5);
            L.ln(dl, cx - 6, cy + 6, cx + 6, cy + 6, u, 1.5);
        },
        .search => icons.search(dl, cx, cy, u),
        .chevron_r => {
            L.ln(dl, cx - 2, cy - 4, cx + 2, cy, u, 1.4);
            L.ln(dl, cx + 2, cy, cx - 2, cy + 4, u, 1.4);
        },
        .chevron_d => {
            L.ln(dl, cx - 4, cy - 2, cx, cy + 2, u, 1.4);
            L.ln(dl, cx, cy + 2, cx + 4, cy - 2, u, 1.4);
        },
        .refresh => {
            c.ImDrawList_PathClear(dl);
            c.ImDrawList_PathArcTo(dl, d.v(cx, cy), 5.5, 0.6, 5.6, 0);
            c.ImDrawList_PathStroke(dl, u, 1.5, 0);
            c.ImDrawList_AddTriangleFilled(dl, d.v(cx + 5, cy - 6), d.v(cx + 6.5, cy - 1), d.v(cx + 1.5, cy - 2), u);
        },
        .filter => {
            c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 6, cy - 5), d.v(cx + 6, cy - 5), d.v(cx, cy + 1), u);
            c.ImDrawList_AddRectFilledEx(dl, d.v(cx - 1, cy), d.v(cx + 1, cy + 6), u, 0, 0);
        },
        .up => {
            L.ln(dl, cx, cy - 6, cx, cy + 6, u, 1.6);
            L.ln(dl, cx - 4, cy - 2, cx, cy - 6, u, 1.6);
            L.ln(dl, cx + 4, cy - 2, cx, cy - 6, u, 1.6);
        },
        .down => {
            L.ln(dl, cx, cy - 6, cx, cy + 6, u, 1.6);
            L.ln(dl, cx - 4, cy + 2, cx, cy + 6, u, 1.6);
            L.ln(dl, cx + 4, cy + 2, cx, cy + 6, u, 1.6);
        },
        .eye => {
            c.ImDrawList_PathClear(dl);
            c.ImDrawList_PathArcTo(dl, d.v(cx, cy + 5), 8, -2.5, -0.64, 0);
            c.ImDrawList_PathStroke(dl, u, 1.4, 0);
            c.ImDrawList_PathClear(dl);
            c.ImDrawList_PathArcTo(dl, d.v(cx, cy - 5), 8, 0.64, 2.5, 0);
            c.ImDrawList_PathStroke(dl, u, 1.4, 0);
            c.ImDrawList_AddCircleFilled(dl, d.v(cx, cy), 2.4, u, 0);
        },
        .gear => {
            c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 4.5, u, 0, 1.6, 0);
            var k: f32 = 0;
            while (k < 6) : (k += 1) {
                const a = k * std.math.pi / 3;
                L.ln(dl, cx + @cos(a) * 5, cy + @sin(a) * 5, cx + @cos(a) * 7.5, cy + @sin(a) * 7.5, u, 2);
            }
        },
    }
}

/// Botão quadrado de barra com ícone e dica. Devolve se foi clicado.
pub fn toolButton(u: *const Ui, r: Rect, which: Icon, on: bool, tip: []const u8) bool {
    const over = u.over(r);
    if (on) rect(u, r.inset(2, 2), pal.sel, 4) else if (over) rect(u, r.inset(2, 2), pal.hover, 4);
    const col = if (which == .record and on) pal.err else if (on) pal.accent else if (over) pal.text else pal.dim;
    icon(u.dl, which, r.x + r.w / 2, r.y + r.h / 2, col);
    if (over) {
        c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
        tooltip(u, tip);
    }
    return over and c.ImGui_IsMouseClicked(0);
}

/// Botão com texto (e ícone opcional), do tamanho do texto. Devolve se foi clicado.
pub fn button(u: *const Ui, x: f32, y: f32, h: f32, label: []const u8, which: ?Icon) struct { clicked: bool, w: f32 } {
    const iw: f32 = if (which != null) 18 else 0;
    const w = u.textW(label) + 16 + iw;
    const r: Rect = .{ .x = x, .y = y, .w = w, .h = h };
    const over = u.over(r);
    rect(u, r, if (over) pal.hover.mix(pal.accent.alpha(0.18), 0.5) else pal.toolbar, 4);
    d.border(u.dl, r, pal.line, 4, 1);
    if (which) |ic| icon(u.dl, ic, x + 12, y + h / 2, if (over) pal.text else pal.dim);
    _ = u.text(x + 8 + iw, u.mid(y, h), if (over) pal.text else pal.dim, label);
    if (over) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    return .{ .clicked = over and c.ImGui_IsMouseClicked(0), .w = w };
}

/// Ficha que liga e desliga (os filtros de tipo da Rede, os níveis do Console).
pub fn chip(u: *const Ui, x: f32, y: f32, h: f32, label: []const u8, on: bool, count: ?u32) struct { clicked: bool, w: f32 } {
    var cb: [16]u8 = undefined;
    const count_s: []const u8 = if (count) |n| std.fmt.bufPrint(&cb, "{d}", .{n}) catch "" else "";
    const cw: f32 = if (count_s.len > 0) d.width(u.font, u.fs - 1.5, count_s) + 10 else 0;
    const w = u.textW(label) + 16 + cw;
    const r: Rect = .{ .x = x, .y = y, .w = w, .h = h };
    const over = u.over(r);
    if (on) rect(u, r, pal.accent.alpha(0.2), h / 2) else if (over) rect(u, r, pal.hover, h / 2);
    _ = u.text(x + 8, u.mid(y, h), if (on) pal.accent else if (over) pal.text else pal.dim, label);
    if (count_s.len > 0) {
        const bx = x + 8 + u.textW(label) + 4;
        const br: Rect = .{ .x = bx, .y = y + (h - 14) / 2, .w = cw - 4, .h = 14 };
        rect(u, br, if (on) pal.accent.alpha(0.3) else pal.line, 7);
        d.text(u.dl, u.font, u.fs - 1.5, bx + 3, br.y + (14 - (u.fs - 1.5) * 1.2) / 2, if (on) pal.accent else pal.dim, count_s);
    }
    if (over) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    return .{ .clicked = over and c.ImGui_IsMouseClicked(0), .w = w };
}

/// Dica no mouse (por cima de tudo).
pub fn tooltip(u: *const Ui, s: []const u8) void {
    if (s.len == 0) return;
    const fg = c.ImGui_GetForegroundDrawList();
    const w = u.textW(s) + 14;
    const m = u.ctx.mouse;
    var x = m.x + 12;
    var y = m.y + 18;
    if (x + w > u.ctx.win.right() + 0) x = m.x - w - 4;
    if (y + 22 > u.ctx.win.bottom() + 1000) y = m.y - 26;
    const vp = c.ImGui_GetMainViewport();
    if (x + w > vp.*.Pos.x + vp.*.Size.x) x = vp.*.Pos.x + vp.*.Size.x - w - 4;
    if (y + 22 > vp.*.Pos.y + vp.*.Size.y) y = m.y - 26;
    const r: Rect = .{ .x = x, .y = y, .w = w, .h = 22 };
    d.shadow(fg, r, 4, 6, Rgba.black.alpha(0.3));
    d.rect(fg, r, pal.toolbar, 4);
    d.border(fg, r, pal.line, 4, 1);
    d.text(fg, u.font, u.fs, x + 7, y + (22 - u.fs * 1.2) / 2, pal.text, s);
}

/// Campo de texto de filtro com lupa e dica. Devolve se o texto mudou.
pub fn search(u: *const Ui, id: [*:0]const u8, r: Rect, buf: []u8, hint: [:0]const u8) bool {
    rect(u, r, pal.input, 4);
    const focused_border = c.ImGui_IsWindowFocused(c.ImGuiFocusedFlags_ChildWindows);
    _ = focused_border;
    d.border(u.dl, r, pal.line, 4, 1);
    icon(u.dl, .search, r.x + 11, r.y + r.h / 2, pal.faint);
    c.ImGui_SetCursorScreenPos(d.v(r.x + 20, r.y + (r.h - u.fs * 1.2 - 4) / 2));
    c.ImGui_PushFontFloat(u.font, u.fs);
    defer c.ImGui_PopFont();
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_FrameBg, .{ .x = 0, .y = 0, .z = 0, .w = 0 });
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Text, vec4(pal.text));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_TextDisabled, vec4(pal.faint));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, d.v(2, 2));
    defer {
        c.ImGui_PopStyleVarEx(1);
        c.ImGui_PopStyleColorEx(3);
    }
    c.ImGui_SetNextItemWidth(r.w - 26);
    const changed = c.ImGui_InputTextWithHint(id, hint.ptr, buf.ptr, buf.len, 0);
    // Esc dentro do campo limpa o filtro.
    if (c.ImGui_IsItemActive() and c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and buf[0] != 0) {
        @memset(buf, 0);
        return true;
    }
    return changed;
}

pub fn vec4(col: Rgba) c.ImVec4 {
    return .{ .x = col.r, .y = col.g, .z = col.b, .w = col.a };
}

pub fn bufStr(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

/// `hay` contém `needle` sem diferenciar maiúsculas (ASCII), como os filtros do navegador.
pub fn has(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// --- Divisória e lista ------------------------------------------------------------

/// Divisória arrastável entre dois painéis. `frac` é a fração do primeiro.
pub fn splitter(u: *const Ui, r: Rect, vertical: bool, frac: *f32, min_a: f32, min_b: f32, id: usize) void {
    const total = if (vertical) r.w else r.h;
    const at = if (vertical) r.x + total * frac.* else r.y + total * frac.*;
    const hr: Rect = if (vertical) .{ .x = at - 3, .y = r.y, .w = 6, .h = r.h } else .{ .x = r.x, .y = at - 3, .w = r.w, .h = 6 };
    c.ImGui_SetCursorScreenPos(d.v(hr.x, hr.y));
    c.ImGui_PushIDInt(@intCast(id));
    _ = c.ImGui_InvisibleButton("##split", d.v(@max(hr.w, 1), @max(hr.h, 1)), 0);
    const active = c.ImGui_IsItemActive();
    const hovered = c.ImGui_IsItemHovered(0);
    c.ImGui_PopID();
    if (active or hovered) c.ImGui_SetMouseCursor(if (vertical) c.ImGuiMouseCursor_ResizeEW else c.ImGuiMouseCursor_ResizeNS);
    if (active and total > 0) {
        const m = u.ctx.mouse;
        const pos = if (vertical) m.x - r.x else m.y - r.y;
        frac.* = std.math.clamp(pos, min_a, @max(min_a, total - min_b)) / total;
    }
    if (vertical) vline(u, at, r.y, r.bottom(), if (active or hovered) pal.accent else pal.line) else hline(u, r.x, r.right(), at, if (active or hovered) pal.accent else pal.line);
}

/// Região com rolagem para uma lista de `n` linhas de altura `row_h`: devolve a faixa
/// visível (de `first` a `last`) e o y da primeira. Quem chama desenha só essas.
pub const List = struct {
    first: usize,
    last: usize,
    y0: f32,
    dl: *c.ImDrawList,
    r: Rect,
    scroll: f32,
};

pub fn beginList(u: *Ui, id: [*:0]const u8, r: Rect, n: usize, row_h: f32, follow: bool, reveal: ?usize) List {
    c.ImGui_SetCursorScreenPos(d.v(r.x, r.y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, d.v(0, 0));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ScrollbarBg, .{ .x = 0, .y = 0, .z = 0, .w = 0 });
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ScrollbarGrab, vec4(pal.line));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ScrollbarGrabHovered, vec4(pal.faint));
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_ScrollbarSize, 9);
    _ = c.ImGui_BeginChild(id, d.v(@max(r.w, 1), @max(r.h, 1)), 0, c.ImGuiWindowFlags_NoBackground);
    c.ImGui_PopStyleVarEx(2);
    c.ImGui_PopStyleColorEx(3);
    const dl = c.ImGui_GetWindowDrawList();
    u.dl = dl;
    const total = @as(f32, @floatFromInt(n)) * row_h;
    // Seguir o fim (logs): enquanto a pessoa está no fim, a lista desce sozinha.
    var scroll = c.ImGui_GetScrollY();
    const max_scroll = @max(0, total - r.h);
    if (follow and scroll >= c.ImGui_GetScrollMaxY() - row_h * 1.5) {
        scroll = max_scroll;
        c.ImGui_SetScrollY(scroll);
    }
    if (reveal) |i| {
        const yi = @as(f32, @floatFromInt(i)) * row_h;
        if (yi < scroll or yi + row_h > scroll + r.h) {
            scroll = std.math.clamp(yi - r.h / 3, 0, max_scroll);
            c.ImGui_SetScrollY(scroll);
        }
    }
    const first: usize = @intFromFloat(@max(0, @floor(scroll / row_h)));
    const shown: usize = @intFromFloat(@ceil(r.h / row_h) + 1);
    return .{ .first = @min(first, n), .last = @min(n, first + shown), .y0 = r.y - scroll + @as(f32, @floatFromInt(first)) * row_h, .dl = dl, .r = r, .scroll = scroll };
}

pub fn endList(u: *Ui, l: List, n: usize, row_h: f32, parent_dl: *c.ImDrawList) void {
    // O tamanho do conteúdo, para a barra de rolagem.
    c.ImGui_SetCursorScreenPos(d.v(l.r.x, l.r.y - l.scroll + @as(f32, @floatFromInt(n)) * row_h));
    c.ImGui_Dummy(d.v(1, 0));
    c.ImGui_EndChild();
    u.dl = parent_dl;
}

/// Região com rolagem livre (painéis de detalhes): quem chama desenha a partir de `y`
/// e devolve onde terminou em `endPane`.
pub fn beginPane(u: *Ui, id: [*:0]const u8, r: Rect) f32 {
    c.ImGui_SetCursorScreenPos(d.v(r.x, r.y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, d.v(0, 0));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ScrollbarBg, .{ .x = 0, .y = 0, .z = 0, .w = 0 });
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ScrollbarGrab, vec4(pal.line));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ScrollbarGrabHovered, vec4(pal.faint));
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_ScrollbarSize, 9);
    _ = c.ImGui_BeginChild(id, d.v(@max(r.w, 1), @max(r.h, 1)), 0, c.ImGuiWindowFlags_NoBackground);
    c.ImGui_PopStyleVarEx(2);
    c.ImGui_PopStyleColorEx(3);
    u.dl = c.ImGui_GetWindowDrawList();
    return r.y - c.ImGui_GetScrollY();
}

pub fn endPane(u: *Ui, r: Rect, y_end: f32, parent_dl: *c.ImDrawList) void {
    c.ImGui_SetCursorScreenPos(d.v(r.x, y_end + 8));
    c.ImGui_Dummy(d.v(1, 0));
    c.ImGui_EndChild();
    u.dl = parent_dl;
}

// --- Texto colorido --------------------------------------------------------------

/// Uma linha montada aos pedaços, cada um com a sua cor (a árvore de elementos, o JSON).
pub const Run = struct {
    u: *const Ui,
    x: f32,
    y: f32,
    max_x: f32,
    mono: bool = true,

    pub fn put(r: *Run, col: Rgba, s: []const u8) void {
        if (r.x >= r.max_x or s.len == 0) return;
        const room = r.max_x - r.x;
        const font = if (r.mono) r.u.mono else r.u.font;
        const size = if (r.mono) r.u.ms else r.u.fs;
        const w = d.width(font, size, s);
        if (w <= room) {
            d.text(r.u.dl, font, size, r.x, r.y, col, s);
            r.x += w;
        } else {
            r.x += d.textClipped(r.u.dl, font, size, r.x, r.y, col, s, room);
            r.x = r.max_x;
        }
    }

    pub fn print(r: *Run, col: Rgba, comptime fmt: []const u8, args: anytype) void {
        var b: [256]u8 = undefined;
        r.put(col, d.printClip(&b, fmt, args));
    }
};

/// Seção com título que abre e fecha (os painéis de detalhes). Devolve se está aberta.
pub fn section(u: *const Ui, x: f32, y: *f32, w: f32, title: []const u8, open: *bool) bool {
    const h: f32 = 24;
    const r: Rect = .{ .x = x, .y = y.*, .w = w, .h = h };
    const over = u.over(r);
    rect(u, r, if (over) pal.hover.mix(pal.toolbar, 0.5) else pal.toolbar, 0);
    hline(u, x, x + w, y.* + h - 1, pal.line);
    icon(u.dl, if (open.*) .chevron_d else .chevron_r, x + 12, y.* + h / 2, pal.dim);
    _ = u.textB(x + 22, u.mid(y.*, h), pal.text, title);
    if (over) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    if (over and c.ImGui_IsMouseClicked(0)) open.* = !open.*;
    y.* += h + 4;
    return open.*;
}

/// Linha "nome: valor" dos painéis de detalhes. O valor pode ser copiado com um clique.
pub fn kv(u: *const Ui, x: f32, y: *f32, w: f32, key: []const u8, value: []const u8, value_col: Rgba) void {
    const h: f32 = 19;
    const kw: f32 = @min(150, w * 0.38);
    _ = u.clip(x + 12, u.mid(y.*, h), pal.dim, key, kw - 16);
    const vr: Rect = .{ .x = x + kw, .y = y.*, .w = w - kw - 6, .h = h };
    const over = u.over(vr);
    if (over) rect(u, vr, pal.hover, 3);
    _ = u.clipCode(x + kw + 2, u.midCode(y.*, h), value_col, value, w - kw - 10);
    if (over and value.len > 0) {
        c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
        if (c.ImGui_IsMouseClicked(0)) copyText(value);
    }
    y.* += h;
}

/// Quadradinho com a cor (e o tabuleiro atrás, para a transparência aparecer).
pub fn swatch(u: *const Ui, r: Rect, col: Rgba) void {
    const half = r.w / 2;
    rect(u, r, Rgba.hex(0xFFFFFF), 2);
    rect(u, .{ .x = r.x, .y = r.y, .w = half, .h = r.h / 2 }, Rgba.hex(0xCCCCCC), 0);
    rect(u, .{ .x = r.x + half, .y = r.y + r.h / 2, .w = half, .h = r.h / 2 }, Rgba.hex(0xCCCCCC), 0);
    rect(u, r, col, 2);
    d.border(u.dl, r, pal.line, 2, 1);
}

pub fn fromU32(v: u32) Rgba {
    return .{
        .r = @as(f32, @floatFromInt(v & 0xff)) / 255,
        .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255,
        .b = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255,
        .a = @as(f32, @floatFromInt((v >> 24) & 0xff)) / 255,
    };
}

/// "#rrggbb" ou "#rrggbbaa" de uma cor do ImGui (ABGR).
pub fn hexOf(buf: []u8, v: u32) []const u8 {
    const r = v & 0xff;
    const g = (v >> 8) & 0xff;
    const b = (v >> 16) & 0xff;
    const a = (v >> 24) & 0xff;
    return if (a == 0xff)
        std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch ""
    else
        std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b, a }) catch "";
}

pub var copied_at_ms: i64 = 0;

pub fn copyText(s: []const u8) void {
    var b: [8192]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&b, "{s}", .{s[0..@min(s.len, b.len - 1)]}, 0) catch return;
    _ = c.SDL_SetClipboardText(z.ptr);
    copied_at_ms = @intCast(c.SDL_GetTicks());
}

/// Copia um texto longo (JSON de uma resposta inteira) sem limite de tamanho.
pub fn copyLong(s: []const u8) void {
    const z = std.heap.c_allocator.allocSentinel(u8, s.len, 0) catch return;
    defer std.heap.c_allocator.free(z);
    @memcpy(z[0..s.len], s);
    _ = c.SDL_SetClipboardText(z.ptr);
    copied_at_ms = @intCast(c.SDL_GetTicks());
}

/// Hora "14:02:33.120" de um instante em ms desde 1970 (no fuso local).
pub fn clock(buf: []u8, ms: i64) []const u8 {
    var dt: c.SDL_DateTime = undefined;
    if (!c.SDL_TimeToDateTime(ms * std.time.ns_per_ms, &dt, true)) return "";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ @as(u32, @intCast(dt.hour)), @as(u32, @intCast(dt.minute)), @as(u32, @intCast(dt.second)), @as(u32, @intCast(@divTrunc(dt.nanosecond, 1_000_000))) }) catch "";
}

pub fn bytesText(buf: []u8, n: usize) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "";
    if (n < 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} kB", .{@as(f64, @floatFromInt(n)) / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d:.2} MB", .{@as(f64, @floatFromInt(n)) / (1024 * 1024)}) catch "";
}

pub fn durText(buf: []u8, us: u64) []const u8 {
    if (us < 1000) return std.fmt.bufPrint(buf, "{d} µs", .{us}) catch "";
    if (us < 1_000_000) return std.fmt.bufPrint(buf, "{d:.1} ms", .{@as(f64, @floatFromInt(us)) / 1000}) catch "";
    return std.fmt.bufPrint(buf, "{d:.2} s", .{@as(f64, @floatFromInt(us)) / 1_000_000}) catch "";
}

const t = std.testing;

test "filtro sem diferenciar maiúsculas" {
    try t.expect(has("MESSAGE_CREATE", "message"));
    try t.expect(has("/channels/1/messages", "MESS"));
    try t.expect(!has("op 1", "op 11"));
    try t.expect(has("qualquer", ""));
}

test "cor do ImGui em hex" {
    var b: [12]u8 = undefined;
    try t.expectEqualStrings("#5865f2", hexOf(&b, 0xFFF26558));
    try t.expectEqualStrings("#5865f280", hexOf(&b, 0x80F26558));
}

test "tamanhos e durações legíveis" {
    var b: [24]u8 = undefined;
    try t.expectEqualStrings("512 B", bytesText(&b, 512));
    try t.expectEqualStrings("1.5 kB", bytesText(&b, 1536));
    try t.expectEqualStrings("850 µs", durText(&b, 850));
    try t.expectEqualStrings("12.3 ms", durText(&b, 12_300));
}
