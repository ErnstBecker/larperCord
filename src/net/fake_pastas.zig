//! As pastas da barra na demonstração (core/pastas.zig): responde como o Discord às
//! gravações e guarda o que "foi mandado" para o QA conferir. As configurações gerais
//! da conta de mentira têm campos que não são as pastas antes e depois delas (e um
//! campo desconhecido dentro de uma pasta e outro na lista), para o QA conferir que
//! gravar não mexe no resto. Roda na thread do gateway falso; os contadores são
//! atômicos porque o QA lê da thread da interface.
const std = @import("std");
const sys = @import("../platform/sys.zig");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const i18n = @import("../ui/i18n.zig");
const settings_proto = @import("settings_proto.zig");
const status_proto = @import("status_proto.zig");
const pastas_net = @import("pastas_net.zig");

const alloc = std.heap.c_allocator;

/// Antes das pastas: versions { client_version: 3, data_version: 7 } e um campo de
/// outra parte (6, texto e imagens). Depois: um campo de número alto (5000).
pub const head = "\x0a\x04\x08\x03\x18\x07" ++ "\x32\x04\x0a\x02\x08\x01";
pub const tail = "\xc2\xb8\x02\x03xyz";
/// Dentro da pasta "Jogos" (78): o campo 9, fixed64, que o app não conhece.
pub const folder_unknown = "\x49\xef\xbe\xad\xde\x00\x00\x00\x00";
/// No fim do `GuildFolders`: o campo 7, fixed32.
pub const list_unknown = "\x3d\x01\x02\x03\x04";
pub const data_version = 7;

pub const sent = struct {
    const A = sys.Atomic(u64);
    /// PATCHes que iriam para o Discord e o corpo do último (o QA decodifica).
    pub var patches: A = .init(0);
    pub var body_len: A = .init(0);
    pub var body: [8192]u8 = undefined;
    /// Gravações pedidas (com ou sem PATCH: a que não muda nada não grava).
    pub var saves: A = .init(0);
    /// Fora das pastas, as configurações continuam iguais byte a byte (1) ou não (0);
    /// e os dois campos desconhecidos das pastas continuam lá.
    pub var intact: A = .init(1);
    pub var unknown_kept: A = .init(1);
    /// A próxima gravação falha como um erro do Discord (o QA liga).
    pub var fail_next: A = .init(0);
};

/// As configurações da conta de mentira (vazias até a primeira gravação).
var settings: std.ArrayList(u8) = .empty;

/// O que "outro aparelho" gravou (o QA põe; a thread do gateway aplica antes da
/// próxima gravação, como se o servidor já tivesse).
var remote_buf: [4096]u8 = undefined;
var remote_len: sys.Atomic(u64) = .init(0);

fn appendField(out: *std.ArrayList(u8), field: u64, data: []const u8) !void {
    var x: u64 = field << 3 | 2;
    while (x >= 0x80) : (x >>= 7) try out.append(alloc, @as(u8, @truncate(x)) | 0x80);
    try out.append(alloc, @truncate(x));
    x = data.len;
    while (x >= 0x80) : (x >>= 7) try out.append(alloc, @as(u8, @truncate(x)) | 0x80);
    try out.append(alloc, @truncate(x));
    try out.appendSlice(alloc, data);
}

/// As configurações com `content` (um `GuildFolders`) no campo das pastas.
fn rebuild(content: []const u8) !void {
    settings.clearRetainingCapacity();
    try settings.appendSlice(alloc, head);
    try appendField(&settings, 14, content);
    try settings.appendSlice(alloc, tail);
}

/// As pastas que a demonstração mostra no READY, nas configurações.
fn seed(demo: []const types.GuildFolder) !void {
    if (settings.items.len > 0) return;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    for (demo) |f| {
        const one = try settings_proto.encodeFolder(alloc, f, if (f.id == 78) folder_unknown else "");
        defer alloc.free(one);
        try appendField(&content, 1, one);
    }
    try content.appendSlice(alloc, list_unknown);
    try rebuild(content.items);
}

/// Aplica o que "outro aparelho" gravou: o campo das pastas dele, como veio.
fn takeRemote() !void {
    const n = remote_len.load(.acquire);
    if (n == 0) return;
    defer remote_len.store(0, .release);
    const only = try settings_proto.foldersOnly(alloc, remote_buf[0..n]);
    defer alloc.free(only);
    settings.clearRetainingCapacity();
    try settings.appendSlice(alloc, head);
    try settings.appendSlice(alloc, only);
    try settings.appendSlice(alloc, tail);
}

fn foldersNow() ?[]types.GuildFolder {
    return pastas_net.foldersOf(settings.items);
}

/// Uma gravação das pastas, como a de verdade (net/pastas_net.zig `save`): lê, aplica,
/// manda só as pastas com a versão e responde com as configurações como ficaram. O
/// gateway avisa depois (USER_SETTINGS_PROTO_UPDATE), também como o de verdade.
pub fn execute(g: anytype, f: ev.FolderEdit, demo: []const types.GuildFolder) !void {
    defer pastas_net.free(f);
    _ = sent.saves.fetchAdd(1, .monotonic);
    try seed(demo);
    try takeRemote();
    if (sent.fail_next.swap(0, .acq_rel) != 0) {
        // Como `noticeHttp` mostra um erro sem mensagem do Discord.
        g.emit(.{ .notice = try i18n.allocPrint(alloc, "{s} (HTTP {d})", "{s} (HTTP {d})", .{ i18n.tr("não deu para salvar as pastas", "couldn't save the folders"), 500 }) });
        g.emit(.{ .folders_saved = .{ .seq = f.seq, .ok = false, .folders = foldersNow() } });
        return;
    }
    const out = settings_proto.edit(alloc, settings.items, f.ops, f.known) catch {
        g.emit(.{ .notice = try i18n.allocPrint(alloc, "não deu para salvar as pastas", "couldn't save the folders", .{}) });
        g.emit(.{ .folders_saved = .{ .seq = f.seq, .ok = false, .folders = foldersNow() } });
        return;
    } orelse {
        g.emit(.{ .folders_saved = .{ .seq = f.seq, .ok = true, .folders = foldersNow() } });
        return;
    };
    defer alloc.free(out);
    const version = status_proto.dataVersion(settings.items) catch null;
    const body = try settings_proto.patchBody(alloc, out, version);
    defer alloc.free(body);
    const n = @min(body.len, sent.body.len);
    @memcpy(sent.body[0..n], body[0..n]);
    sent.body_len.store(n, .release);
    settings.clearRetainingCapacity();
    try settings.appendSlice(alloc, out);
    const items = settings.items;
    sent.intact.store(@intFromBool(std.mem.startsWith(u8, items, head) and std.mem.endsWith(u8, items, tail)), .release);
    sent.unknown_kept.store(@intFromBool(std.mem.indexOf(u8, items, list_unknown) != null and
        (std.mem.indexOf(u8, items, folder_unknown) != null or !hasFolder(items, 78))), .release);
    _ = sent.patches.fetchAdd(1, .release);
    g.emit(.{ .folders_saved = .{ .seq = f.seq, .ok = true, .folders = foldersNow() } });
    if (foldersNow()) |list| g.emit(.{ .guild_folders = list });
}

fn hasFolder(bytes: []const u8, id: u64) bool {
    const l = settings_proto.fromProto(alloc, bytes) catch return false;
    defer l.deinit(alloc);
    for (l.folders) |f| if (f.id == id) return true;
    return false;
}

/// "Outro aparelho" mudou as pastas: o USER_SETTINGS_PROTO_UPDATE (só o campo 14,
/// `partial`), lido pelo mesmo leitor do gateway de verdade. Chamado pelo QA; a
/// conta de mentira passa a ter essas pastas na próxima gravação.
pub fn remote(proto: []const u8) ?ev.Event {
    if (proto.len > remote_buf.len) return null;
    @memcpy(remote_buf[0..proto.len], proto);
    remote_len.store(proto.len, .release);
    var b: [8192]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    if (enc.calcSize(proto.len) > b.len) return null;
    return pastas_net.eventFromBase64(enc.encode(&b, proto));
}

pub fn deinit() void {
    settings.deinit(alloc);
    settings = .empty;
}
