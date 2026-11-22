//! Transmissão de tela do lado do app: começar e parar a nossa, assistir e parar
//! de assistir a de alguém, e o que fazer com o que o gateway avisa (acabou,
//! quantos assistem, quem parou de transmitir).
//!
//! A ordem de começar: primeiro a captura (net/golive_media.zig), que no Wayland
//! abre o diálogo do sistema; só quando ela de fato começa sai o op 18. Cancelar o
//! diálogo não deixa transmissão nenhuma aberta no Discord.
const std = @import("std");
const App = @import("app.zig").App;
const ev = @import("core/event.zig");
const types = @import("core/types.zig");
const golive_media = @import("net/golive_media.zig");
const golive_view = @import("ui/golive_view.zig");
const tela = @import("platform/tela.zig");
const qa = @import("ui/qa.zig");
const now = @import("net/fake_gateway.zig").nowMs;
const Id = types.Id;

/// "Transmitir" no painel: abre a captura do que foi escolhido.
pub fn share(app: *App, choice: ev.GoliveShare) void {
    const st = &app.st;
    const vch = st.voice orelse return st.showToast(now(), true, "entre numa call para transmitir", "join a call to go live", .{});
    _ = vch;
    if (st.golive.share != .off) stop(app);
    var target: tela.Target = .{ .kind = tela.native() };
    // O QA e LARPER_SCREEN_SYNTHETIC: a tela sintética (sem diálogo do sistema).
    if (qa.compiled or @import("c").SDL_getenv("LARPER_SCREEN_SYNTHETIC") != null) target = .{ .kind = .synthetic, .w = 1280, .h = 720 };
    if (target.kind == .x11 or target.kind == .gdi) {
        var buf: [8]tela.Screen = undefined;
        const scrs = tela.screens(&buf);
        if (scrs.len == 0) return st.showToast(now(), true, "nenhuma tela para transmitir", "no screen to share", .{});
        const s = scrs[@min(choice.screen, scrs.len - 1)];
        target.x = s.x;
        target.y = s.y;
        target.w = s.w;
        target.h = s.h;
    }
    if (!golive_media.startShare(target, golive_view.qualityAt(choice.quality))) {
        return st.showToast(now(), true, "não deu para começar a transmissão", "couldn't start the stream", .{});
    }
    st.golive.share = .opening;
    st.golive.announced = false;
    st.golive.viewers = 0;
}

/// Parar a nossa (botão, sair da call, a captura acabou).
pub fn stop(app: *App) void {
    const st = &app.st;
    if (st.golive.share == .off) return;
    golive_media.stopShare();
    golive_media.clearShare();
    golive_view.dropPreview();
    if (st.golive.announced) app.cmd(.golive_stop);
    st.golive.share = .off;
    st.golive.announced = false;
    st.golive.share_link = .disconnected;
    st.golive.viewers = 0;
}

pub fn watch(app: *App, user: Id) void {
    const st = &app.st;
    const vch = st.voice orelse return;
    if (user == app.store.me) return;
    if (st.golive.watching != 0) unwatch(app);
    const ok = if (app.store.demo) golive_media.demoWatch(user) else golive_media.watchBegin(user);
    if (!ok) return st.showToast(now(), true, "não deu para assistir", "couldn't watch", .{});
    st.golive.watching = user;
    st.golive.focus = false;
    st.golive.watch_link = .connecting;
    app.cmd(.{ .golive_watch = .{ .guild = st.voice_guild, .channel = vch, .user = user } });
    // Numa call de servidor, a transmissão aparece na tela da call.
    if (st.voice_guild != 0 and !st.call_view) app.handle(.{ .show_call = vch });
}

pub fn unwatch(app: *App) void {
    const st = &app.st;
    if (st.golive.watching == 0) return;
    golive_media.watchEnd();
    golive_view.dropWatch();
    app.cmd(.golive_unwatch);
    st.golive.watching = 0;
    st.golive.focus = false;
    st.golive.watch_link = .disconnected;
}

/// Saímos da call (ou trocamos): nada de transmissão continua. O gateway já
/// encerra as do Discord junto com a call.
pub fn reset(app: *App) void {
    const st = &app.st;
    if (st.golive.share != .off) {
        golive_media.stopShare();
        golive_media.clearShare();
        golive_view.dropPreview();
    }
    if (st.golive.watching != 0) {
        golive_media.watchEnd();
        golive_view.dropWatch();
    }
    st.golive = .{ .pick_screen = st.golive.pick_screen, .pick_quality = st.golive.pick_quality };
}

/// A cada quadro (só olha números): a captura começou, falhou ou acabou.
pub fn update(app: *App) void {
    const st = &app.st;
    if (st.golive.share == .off) return;
    var mb: [48]u8 = undefined;
    const info = golive_media.shareInfo(&mb);
    switch (info.state) {
        .idle, .opening => {},
        .live => if (!st.golive.announced) {
            const vch = st.voice orelse return stop(app);
            st.golive.announced = true;
            st.golive.share = .live;
            app.cmd(.{ .golive_start = .{ .guild = st.voice_guild, .channel = vch } });
        },
        .ended => {
            stop(app);
            st.showToast(now(), false, "transmissão encerrada", "stream ended", .{});
        },
        .failed => {
            const fail = info.fail;
            const what = info.missing;
            stop(app);
            switch (fail) {
                .cancelled => {},
                .missing => st.showToast(now(), true, "para transmitir falta {s}", "{s} is needed to go live", .{what}),
                .no_portal => st.showToast(now(), true, "o sistema não ofereceu a captura de tela (xdg-desktop-portal)", "the system didn't offer screen capture (xdg-desktop-portal)", .{}),
                .no_encoder => st.showToast(now(), true, "o FFmpeg não tem codificador {s}", "FFmpeg has no {s} encoder", .{what}),
                .capture, .none => st.showToast(now(), true, "a captura da tela falhou", "screen capture failed", .{}),
            }
        },
    }
}

/// Cada evento da rede, depois do Store.
pub fn onEvent(app: *App, e: ev.Event) void {
    const st = &app.st;
    switch (e) {
        .golive => |g| switch (g) {
            .link => |l| if (l.watch) {
                st.golive.watch_link = l.status;
            } else {
                st.golive.share_link = l.status;
            },
            .viewers => |n| st.golive.viewers = n,
            .ended => |x| if (x.watch) {
                if (st.golive.watching == x.user and x.user != 0) {
                    golive_media.watchEnded();
                    st.golive.watch_link = .disconnected;
                    if (x.reason == .full) st.showToast(now(), true, "a transmissão está cheia", "the stream is full", .{});
                    if (x.reason == .dropped) st.showToast(now(), true, "a conexão com a transmissão caiu", "the connection to the stream dropped", .{});
                }
            } else if (st.golive.share != .off) {
                const was = st.golive.announced;
                // O Discord já encerrou: não manda o op 19 de novo.
                st.golive.announced = false;
                stop(app);
                if (was and x.reason == .dropped) st.showToast(now(), true, "a transmissão caiu", "the stream dropped", .{});
            },
        },
        // Quem assistimos parou de transmitir ou saiu da call: fica o último quadro
        // com o aviso de que acabou.
        .voice_state => |vs| if (st.golive.watching != 0 and vs.user == st.golive.watching) {
            const gone = vs.channel == null or vs.channel.? != (st.voice orelse 0);
            if (gone or !vs.flags.self_stream) golive_media.watchEnded();
        },
        else => {},
    }
}
