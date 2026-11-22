//! QA da transmissão de tela (app_golive.zig, ui/golive_view.zig,
//! net/golive_media.zig), na call da madrugada da demonstração, onde o kaique
//! está transmitindo. Assistir: o botão no quadro dele abre o palco, a tela sintética
//! passa pelo caminho inteiro (codificar em H.264, empacotar em RTP com um pacote
//! perdido de vez em quando, remontar, decodificar) e chega imagem; tela cheia e Esc;
//! parar de assistir. Transmitir: o botão da barra abre o painel, a qualidade
//! escolhida vale, a captura (sintética no QA) começa, o selo AO VIVO e a prévia
//! aparecem no nosso quadro, "2 assistindo" chega, e o botão para tudo. Sair da call
//! assistindo e transmitindo encerra os dois. Sozinho: QA_SUITE=golive. Precisa do
//! FFmpeg com um codificador de H.264 (sem ele, só o painel com o aviso).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const golive_media = @import("net/golive_media.zig");
const video_codec = @import("platform/video_codec.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn expectSlow(name: []const u8, f: *const fn (*App) bool, ms: u32) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = ms } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}

const g0: Id = gw.guildId(0);
const call0: Id = gw.channelId(0, 13);
const me: Id = 1000;
const kaique: Id = 1003;

/// Sem FFmpeg com H.264, a parte da imagem não tem como passar: só confere o aviso.
fn canEncode() bool {
    return video_codec.canEncode(.h264);
}

fn joinCall(app: *App) void {
    app.handle(.{ .select_guild = g0 });
    app.handle(.{ .toggle_voice = call0 });
    app.handle(.{ .show_call = call0 });
}
fn inCall(app: *App) bool {
    return app.st.voice == call0 and app.st.call_view and qa.find("grid-view") != null and qa.find("grid-tile:1003") != null;
}
fn watchButton(_: *App) bool {
    // O kaique transmite: o botão está no quadro dele; no nosso, não.
    return qa.find("grid-watch:1003") != null and qa.find("grid-watch:1000") == null and qa.find("grid-live:1003") != null;
}
fn sidebarLive(_: *App) bool {
    return qa.find("voice-live") != null;
}
fn shareButton(app: *App) bool {
    return qa.find("grid-share") != null and app.st.golive.share == .off;
}

// --- Assistir ---------------------------------------------------------------

fn watching(app: *App) bool {
    return app.st.golive.watching == kaique and qa.find("golive-stage") != null and qa.find("golive-stage-name:1003") != null;
}
fn tilesBelow(_: *App) bool {
    // Os quadros continuam, numa faixa embaixo do palco.
    const st = qa.find("golive-stage") orelse return false;
    const t = qa.find("grid-tile:1001") orelse return false;
    return t.y >= st.y + st.h - 1;
}
fn pictureArrives(app: *App) bool {
    if (!canEncode()) return true;
    return golive_media.watchDecoded() >= 10 and golive_media.watchState() == .playing and qa.find("golive-video") != null and app.st.golive.watch_link == .connected;
}
fn videoFillsWidth(_: *App) bool {
    if (!canEncode()) return true;
    // 16:9 no palco: a imagem encosta nos lados (ou em cima e embaixo).
    const st = qa.find("golive-stage") orelse return false;
    const v = qa.find("golive-video") orelse return false;
    return @abs(v.w - st.w) <= 2 or @abs(v.h - st.h) <= 2;
}
var decoded_before: u32 = 0;
fn noteDecoded(_: *App) void {
    decoded_before = golive_media.watchDecoded();
}
fn keepsComing(_: *App) bool {
    if (!canEncode()) return true;
    // ~30 qps; com o pacote perdido de vez em quando, o quadro-chave pedido volta logo.
    return golive_media.watchDecoded() >= decoded_before + 60;
}
fn focused(app: *App) bool {
    return app.st.golive.focus and qa.find("golive-stage") != null and qa.find("grid-tile:1001") == null;
}
fn unfocused(app: *App) bool {
    return !app.st.golive.focus and qa.find("grid-tile:1001") != null and app.st.call_view;
}
fn stoppedWatching(app: *App) bool {
    return app.st.golive.watching == 0 and qa.find("golive-stage") == null and golive_media.watchUser() == 0 and qa.find("grid-watch:1003") != null;
}

// --- Transmitir -------------------------------------------------------------

fn pickerOpen(app: *App) bool {
    return app.st.popup == .golive and qa.find("golive-picker") != null and qa.find("golive-quality:0") != null and qa.find("golive-go") != null;
}
fn pickerWarns(_: *App) bool {
    // Sem codificador, o aviso aparece e o botão não faz nada.
    return canEncode() == (qa.find("golive-missing") == null);
}
fn quality1(app: *App) bool {
    return app.st.golive.pick_quality == 1;
}
fn sharing(app: *App) bool {
    if (!canEncode()) return app.st.golive.share == .off;
    return app.st.golive.share == .live and app.st.golive.announced and app.store.voiceFlags(me).self_stream and qa.find("grid-live:1000") != null;
}
fn qualityUsed(_: *App) bool {
    if (!canEncode()) return true;
    var b: [48]u8 = undefined;
    const info = golive_media.shareInfo(&b);
    // 1080p 30 de uma tela sintética de 1280×720: não aumenta.
    return info.quality == .p1080_30 and info.w == 1280 and info.h == 720 and info.encoded > 5;
}
/// Os temas de terminal mostram a call em linhas de texto: sem quadro para a prévia.
fn textGrid() bool {
    const t = qa.find("grid-tile:1000") orelse return false;
    return t.h < 40;
}
fn previewInTile(_: *App) bool {
    if (!canEncode() or textGrid()) return true;
    return qa.find("golive-preview") != null;
}
fn viewers(app: *App) bool {
    if (!canEncode()) return true;
    return app.st.golive.viewers == 2 and qa.find("grid-viewers:2") != null;
}
fn stoppedSharing(app: *App) bool {
    var b: [48]u8 = undefined;
    return app.st.golive.share == .off and !app.store.voiceFlags(me).self_stream and qa.find("golive-preview") == null and golive_media.shareInfo(&b).state == .idle;
}

// --- Sair da call -------------------------------------------------------------

fn startBoth(app: *App) void {
    app.handle(.{ .golive_watch = kaique });
    app.handle(.{ .golive_share = .{ .quality = 0 } });
}
fn bothOn(app: *App) bool {
    if (!canEncode()) return app.st.golive.watching == kaique;
    return app.st.golive.watching == kaique and app.st.golive.share == .live;
}
fn leave(app: *App) void {
    app.handle(.leave_voice);
}
fn allOff(app: *App) bool {
    var b: [48]u8 = undefined;
    return app.st.voice == null and app.st.golive.watching == 0 and app.st.golive.share == .off and
        golive_media.watchUser() == 0 and golive_media.shareInfo(&b).state == .idle;
}

pub const ops = [_]Op{
    s("transmissão: a call"),
    run(joinCall),
    expect("entra na call da madrugada e abre a grade", inCall),
    expect("o kaique transmite: AO VIVO e o botão de assistir no quadro dele", watchButton),
    expect("o botão de transmitir está na barra da call", shareButton),
    expect("na lista de canais, o selo AO VIVO de quem transmite", sidebarLive),

    s("transmissão: assistir"),
    click("grid-watch:1003"),
    expect("assistir abre o palco com o nome de quem transmite", watching),
    expect("os quadros continuam, numa faixa embaixo do palco", tilesBelow),
    expectSlow("a imagem chega: codificada, em RTP, remontada e decodificada", pictureArrives, 8000),
    expect("a imagem cabe no palco sem distorcer", videoFillsWidth),
    shot("golive-assistindo"),
    run(noteDecoded),
    expectSlow("os quadros continuam chegando (e voltam depois de um pacote perdido)", keepsComing, 8000),
    click("golive-focus"),
    expect("tela cheia: só a transmissão, sem os quadros", focused),
    key(c.ImGuiKey_Escape),
    expect("Esc volta os quadros (e continua na tela da call)", unfocused),
    click("golive-unwatch"),
    expect("parar de assistir tira o palco e para a decodificação", stoppedWatching),

    s("transmissão: transmitir"),
    click("grid-share"),
    expect("o botão abre o painel de transmitir", pickerOpen),
    expect("o painel avisa só se falta o codificador", pickerWarns),
    click("golive-quality:1"),
    expect("escolher 1080p marca a opção", quality1),
    shot("golive-painel"),
    click("golive-go"),
    expectSlow("transmitindo: a captura começou, o op 18 saiu e o selo AO VIVO está no nosso quadro", sharing, 6000),
    expect("a qualidade escolhida vale (sem aumentar a tela)", qualityUsed),
    expectSlow("a prévia da nossa tela aparece no nosso quadro", previewInTile, 3000),
    expectSlow("quem assiste aparece ao lado do selo", viewers, 8000),
    shot("golive-transmitindo"),
    click("grid-share"),
    expect("o mesmo botão para a transmissão", stoppedSharing),

    s("transmissão: sair da call"),
    run(startBoth),
    expectSlow("assistindo e transmitindo ao mesmo tempo", bothOn, 6000),
    run(leave),
    expect("sair da call encerra as duas", allOff),
};
