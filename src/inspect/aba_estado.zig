//! Aba Estado: o básico do que o app tem agora — a sessão (conexão, conta, quantos
//! servidores, canais e pessoas), a conversa aberta (o que está carregado dela), o tema
//! (cada cor com o nome e o hex, as opções) e a janela (tamanho, escala, renderizador).
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const i18n = @import("../ui/i18n.zig");
const kit = @import("kit.zig");
const theme_mod = @import("../theme/theme.zig");
const App = @import("../app.zig").App;

var sec_session = true;
var sec_channel = true;
var sec_theme = true;
var sec_window = true;

pub fn draw(u: *kit.Ui, app: *App, r: kit.Rect) void {
    const parent = u.dl;
    kit.rect(u, r, kit.pal.panel, 0);
    var y = kit.beginPane(u, "##state", r);
    const x = r.x;
    const w = r.w - 10;
    var b: [160]u8 = undefined;
    const st = &app.store;
    if (kit.section(u, x, &y, w + 10, i18n.tr("Sessão", "Session"), &sec_session)) {
        kit.kv(u, x, &y, w, i18n.tr("Conexão", "Connection"), @tagName(st.connection), if (st.connection == .ready) kit.pal.ok else kit.pal.warn);
        kit.kv(u, x, &y, w, i18n.tr("Modo", "Mode"), if (st.demo) i18n.tr("demonstração", "demo") else if (st.from_cache) i18n.tr("aberto pelo cache, esperando o READY", "opened from cache, waiting for READY") else i18n.tr("conta conectada", "account connected"), kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Sua conta", "Your account"), std.fmt.bufPrint(&b, "{s} ({d})", .{ st.me_username orelse "?", st.me }) catch "", kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Servidores / canais / pessoas", "Servers / channels / people"), std.fmt.bufPrint(&b, "{d} / {d} / {d}", .{ st.guilds.items.len, st.channels.count(), st.users.count() }) catch "", kit.pal.num);
        kit.kv(u, x, &y, w, i18n.tr("Latência", "Latency"), std.fmt.bufPrint(&b, "{d} ms", .{st.latency_ms}) catch "", kit.pal.num);
        kit.kv(u, x, &y, w, i18n.tr("Mensagens por canal (teto)", "Messages per channel (cap)"), std.fmt.bufPrint(&b, "{d}", .{st.max_messages}) catch "", kit.pal.num);
        y += 6;
    }
    if (kit.section(u, x, &y, w + 10, i18n.tr("Conversa aberta", "Open conversation"), &sec_channel)) {
        if (app.st.activeChannel()) |id| if (st.channel(id)) |cs| {
            kit.kv(u, x, &y, w, i18n.tr("Canal", "Channel"), std.fmt.bufPrint(&b, "{s} ({d})", .{ cs.info.name, id }) catch "", kit.pal.text);
            kit.kv(u, x, &y, w, i18n.tr("Servidor", "Server"), std.fmt.bufPrint(&b, "{d}", .{cs.info.guild}) catch "", kit.pal.num);
            kit.kv(u, x, &y, w, i18n.tr("Tipo", "Type"), @tagName(cs.info.kind), kit.pal.text);
            kit.kv(u, x, &y, w, i18n.tr("Mensagens carregadas", "Messages loaded"), std.fmt.bufPrint(&b, "{d}", .{cs.messages.items.len}) catch "", kit.pal.num);
            kit.kv(u, x, &y, w, i18n.tr("Histórico", "History"), std.fmt.bufPrint(&b, "{s} · mais antigas: {s}", .{ @tagName(cs.history), @tagName(cs.older) }) catch "", kit.pal.text);
            kit.kv(u, x, &y, w, i18n.tr("Lida até", "Read up to"), std.fmt.bufPrint(&b, "{d}", .{cs.read_id}) catch "", kit.pal.num);
            kit.kv(u, x, &y, w, i18n.tr("Veio do cache", "Came from cache"), if (cs.cached) i18n.tr("sim", "yes") else i18n.tr("não", "no"), kit.pal.text);
            if (cs.messages.items.len > 0) {
                const last = cs.messages.items[cs.messages.items.len - 1];
                kit.kv(u, x, &y, w, i18n.tr("Última mensagem", "Last message"), std.fmt.bufPrint(&b, "{d}", .{last.msg.id}) catch "", kit.pal.num);
            }
        } else {
            _ = u.text(x + 12, y + 2, kit.pal.faint, i18n.tr("Nenhuma conversa aberta.", "No conversation open."));
            y += 22;
        } else {
            _ = u.text(x + 12, y + 2, kit.pal.faint, i18n.tr("Nenhuma conversa aberta.", "No conversation open."));
            y += 22;
        }
        y += 6;
    }
    if (kit.section(u, x, &y, w + 10, i18n.tr("Tema", "Theme"), &sec_theme)) {
        const th = app.themes.theme_();
        kit.kv(u, x, &y, w, i18n.tr("Nome", "Name"), app.themes.name(), kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Arquivo", "File"), @import("aba_elementos.zig").themeFile(), kit.pal.hl_scope);
        kit.kv(u, x, &y, w, i18n.tr("Modo", "Mode"), @tagName(app.themes.mode), kit.pal.text);
        y += 4;
        // As cores, em duas colunas quando cabe.
        const cols: usize = if (w > 520) 2 else 1;
        const colw = (w - 10) / @as(f32, @floatFromInt(cols));
        var k: usize = 0;
        inline for (@typeInfo(theme_mod.Token).@"enum".field_names) |name| {
            defer k += 1;
            const col = th.c(@field(theme_mod.Token, name));
            const cx = x + 12 + @as(f32, @floatFromInt(k % cols)) * colw;
            const cy = y + @as(f32, @floatFromInt(k / cols)) * 20;
            kit.swatch(u, .{ .x = cx, .y = cy + 4, .w = 12, .h = 12 }, col);
            _ = u.code(cx + 20, u.midCode(cy, 20), kit.pal.key, name);
            var hx: [12]u8 = undefined;
            const hex = kit.hexOf(&hx, col.u());
            const rr: kit.Rect = .{ .x = cx, .y = cy, .w = colw - 8, .h = 20 };
            if (u.over(rr)) {
                kit.rect(u, rr, kit.pal.hover, 3);
                if (c.ImGui_IsMouseClicked(0)) kit.copyText(hex);
            }
            _ = u.code(cx + colw - 90, u.midCode(cy, 20), kit.pal.value, hex);
        }
        y += @as(f32, @floatFromInt((k + cols - 1) / cols)) * 20 + 8;
    }
    if (kit.section(u, x, &y, w + 10, i18n.tr("Janela", "Window"), &sec_window)) {
        const io = app.io;
        kit.kv(u, x, &y, w, i18n.tr("Tamanho (pontos)", "Size (points)"), std.fmt.bufPrint(&b, "{d:.0} × {d:.0}", .{ io.*.DisplaySize.x, io.*.DisplaySize.y }) catch "", kit.pal.num);
        kit.kv(u, x, &y, w, i18n.tr("Escala da interface", "Interface scale"), std.fmt.bufPrint(&b, "{d:.2} (pixels por ponto {d:.2})", .{ app.uiScale(), io.*.DisplayFramebufferScale.x }) catch "", kit.pal.num);
        kit.kv(u, x, &y, w, i18n.tr("Renderizador", "Renderer"), if (c.SDL_GetRendererName(app.win.renderer)) |n| std.mem.span(n) else "?", kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Vídeo", "Video"), if (c.SDL_GetCurrentVideoDriver()) |n| std.mem.span(n) else "?", kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Sistema", "System"), std.fmt.bufPrint(&b, "{s} {s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) }) catch "", kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Versão", "Version"), @import("../core/version.zig").number, kit.pal.text);
        y += 6;
    }
    kit.endPane(u, r, y, parent);
}

/// O mesmo em texto, para o comando `state`.
pub fn texto(app: *App, w: *std.Io.Writer) @import("comandos.zig").Fim {
    const st = &app.store;
    w.print("conexão: {s}{s}\n", .{ @tagName(st.connection), if (st.demo) " (demonstração)" else "" }) catch {};
    w.print("conta: {s} ({d})\n", .{ st.me_username orelse "?", st.me }) catch {};
    w.print("servidores {d}, canais {d}, pessoas {d}, latência {d} ms\n", .{ st.guilds.items.len, st.channels.count(), st.users.count(), st.latency_ms }) catch {};
    if (app.st.activeChannel()) |id| if (st.channel(id)) |cs| {
        w.print("conversa aberta: {s} ({d}), servidor {d}, {d} mensagens, histórico {s}\n", .{ cs.info.name, id, cs.info.guild, cs.messages.items.len, @tagName(cs.history) }) catch {};
    };
    w.print("tema: {s} ({s}), arquivo {s}\n", .{ app.themes.name(), @tagName(app.themes.mode), @import("aba_elementos.zig").themeFile() }) catch {};
    w.print("janela: {d:.0}×{d:.0} pontos, escala {d:.2}\n", .{ app.io.*.DisplaySize.x, app.io.*.DisplaySize.y, app.uiScale() }) catch {};
    return .pronto;
}
