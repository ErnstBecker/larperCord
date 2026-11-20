//! As pastas da barra no Discord de verdade (core/pastas.zig, net/settings_proto.zig):
//! gravar o que mudou aqui e passar adiante o que vem nas configurações. Roda na
//! thread da rede, chamado pelo gateway de net/discord.zig (`g` é o `Gateway` de lá).
//! Cada gravação é um GET e um PATCH, como as estrelas dos GIFs: sempre sobre uma
//! cópia nova das configurações, com só o campo das pastas no PATCH.
const std = @import("std");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const settings_proto = @import("settings_proto.zig");
const status_proto = @import("status_proto.zig");
const j = @import("jsonx.zig");
const i18n = @import("../ui/i18n.zig");
const Value = std.json.Value;

const alloc = std.heap.c_allocator;

/// As pastas de `layout` como a lista do Store (c_allocator). Consome `layout`.
/// `keep_empty`: sem pasta nenhuma, devolve a lista vazia em vez de null (uma
/// resposta de gravação diz como ficou, mesmo vazia).
pub fn toFolders(layout: settings_proto.Layout, keep_empty: bool) ?[]types.GuildFolder {
    defer layout.deinit(alloc);
    if (layout.folders.len == 0 and !keep_empty) return null;
    const out = alloc.alloc(types.GuildFolder, layout.folders.len) catch return null;
    var n: usize = 0;
    for (layout.folders) |f| {
        const guilds = alloc.dupe(types.Id, f.guilds) catch continue;
        const name = alloc.dupe(u8, f.name) catch {
            alloc.free(guilds);
            continue;
        };
        out[n] = .{ .id = f.id, .name = name, .color = f.color, .guilds = guilds };
        n += 1;
    }
    return out[0..n];
}

/// As pastas das configurações `bytes` (já decodificadas). null: não deu para ler.
pub fn foldersOf(bytes: []const u8) ?[]types.GuildFolder {
    const layout = settings_proto.fromProto(alloc, bytes) catch return null;
    return toFolders(layout, true);
}

/// As pastas de um `user_settings_proto` / USER_SETTINGS_PROTO_UPDATE (base64), como
/// o evento que o Store recebe. null: não veio pasta (uma atualização parcial sem
/// elas não apaga as que já temos) ou não deu para ler.
pub fn eventFromBase64(b64: []const u8) ?ev.Event {
    const layout = settings_proto.fromProtoBase64(alloc, b64) catch return null;
    return .{ .guild_folders = toFolders(layout, false) orelse return null };
}

fn decode(a: std.mem.Allocator, b64: []const u8) ?[]u8 {
    return status_proto.decodeBase64(a, b64) catch null;
}

/// As configurações gerais (tipo 1) como estão agora na conta, já decodificadas.
fn current(g: anytype, a: std.mem.Allocator) ?[]u8 {
    var resp = g.request("GET", "/users/@me/settings-proto/1", null) orelse {
        g.notice("não deu para ler as pastas da conta", "couldn't read the account's folders", .{});
        return null;
    };
    defer resp.body.deinit(alloc);
    if (resp.status != 200) {
        g.noticeHttp(i18n.tr("não deu para ler as pastas da conta", "couldn't read the account's folders"), &resp);
        return null;
    }
    const v = std.json.parseFromSliceLeaky(Value, a, resp.body.items, .{}) catch return null;
    return decode(a, j.str(j.get(v, "settings")) orelse return null);
}

fn done(g: anytype, seq: u32, ok: bool, bytes: ?[]const u8) void {
    g.emit(.{ .folders_saved = .{ .seq = seq, .ok = ok, .folders = if (bytes) |b| foldersOf(b) else null } });
}

/// Grava as mudanças nas pastas: lê as configurações de novo, aplica as operações e
/// manda só o campo das pastas, com a versão lida. Se outro aparelho gravou no meio,
/// o Discord recusa em vez de voltar a mudança dele, e as operações são aplicadas de
/// novo sobre o que ficou lá (uma vez). Dando errado, a barra volta ao que está na
/// conta e um aviso diz por quê.
pub fn save(g: anytype, f: ev.FolderEdit) void {
    const what = i18n.tr("não deu para salvar as pastas", "couldn't save the folders");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var tries: u8 = 0;
    while (true) : (tries += 1) {
        const raw = current(g, a) orelse return done(g, f.seq, false, null);
        const out = settings_proto.edit(a, raw, f.ops, f.known) catch {
            g.notice("{s}: as configurações da conta vieram num formato que o app não entende", "{s}: the account settings came in a format the app doesn't understand", .{what});
            return done(g, f.seq, false, raw);
        } orelse return done(g, f.seq, true, raw);
        // Sem a versão (o formato mudou), o corpo vai sem ela.
        const version = status_proto.dataVersion(raw) catch null;
        const body = settings_proto.patchBody(a, out, version) catch return done(g, f.seq, false, raw);
        var resp = g.request("PATCH", "/users/@me/settings-proto/1", body) orelse {
            g.notice("{s}", "{s}", .{what});
            return done(g, f.seq, false, raw);
        };
        defer resp.body.deinit(alloc);
        if (resp.status >= 300) {
            g.noticeHttp(what, &resp);
            return done(g, f.seq, false, raw);
        }
        const v = std.json.parseFromSliceLeaky(Value, a, resp.body.items, .{}) catch null;
        const stale = if (v) |x| if (j.get(x, "out_of_date")) |o| o == .bool and o.bool else false else false;
        // A resposta traz as configurações como ficaram (sem ela, vale o que foi mandado).
        const saved = if (v) |x| if (j.str(j.get(x, "settings"))) |st| decode(a, st) else null else null;
        if (stale) {
            // Outro aparelho gravou entre o GET e o PATCH: lê de novo e refaz as mudanças.
            if (tries == 0) continue;
            g.notice("as configurações mudaram em outro aparelho: tente de novo", "the settings changed on another device: try again", .{});
            return done(g, f.seq, false, saved orelse raw);
        }
        return done(g, f.seq, true, saved orelse out);
    }
}

pub fn free(f: ev.FolderEdit) void {
    alloc.free(f.ops);
    alloc.free(f.known);
}
