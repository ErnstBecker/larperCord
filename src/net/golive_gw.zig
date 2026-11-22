//! Transmissão de tela no gateway principal (net/discord.zig): o op 18 que abre
//! a nossa, o op 20 que pede para assistir a de alguém, o op 19 que encerra (ou
//! para de assistir), e os eventos STREAM_CREATE, STREAM_SERVER_UPDATE,
//! STREAM_UPDATE e STREAM_DELETE. Cada transmissão é uma conexão de voz à parte
//! (net/voice.zig, `kind` de transmissão), aberta quando chegam o servidor e o
//! token e fechada quando ela acaba.
//!
//! `g` é o Gateway (anytype: sem import circular): `writeWs`, `emit`, `notice`,
//! `me`, `sink`, a sessão de voz e o canal da call.
const std = @import("std");
const ev = @import("../core/event.zig");
const golive = @import("../core/golive.zig");
const golive_json = @import("golive_json.zig");
const golive_media = @import("golive_media.zig");
const voice_mod = @import("voice.zig");
const j = @import("jsonx.zig");
const Value = std.json.Value;
const Id = u64;
const alloc = std.heap.c_allocator;

/// Uma transmissão nossa ou assistida.
pub const Link = struct {
    key: ?golive.Key = null,
    rtc: Id = 0,
    endpoint: [256]u8 = @splat(0),
    endpoint_len: usize = 0,
    token: [256]u8 = @splat(0),
    token_len: usize = 0,
    conn: ?*voice_mod.Voice = null,

    fn matches(l: *const Link, k: golive.Key) bool {
        const mine = l.key orelse return false;
        return mine.eql(k);
    }

    fn kill(l: *Link) void {
        if (l.conn) |vc| {
            vc.stop();
            vc.deinit();
            alloc.destroy(vc);
            l.conn = null;
        }
    }

    fn clear(l: *Link) void {
        l.kill();
        std.crypto.secureZero(u8, &l.token);
        l.* = .{};
    }
};

pub const Links = struct {
    out: Link = .{},
    in: Link = .{},

    /// Comandos da interface.
    pub fn command(ls: *Links, g: anytype, cmd: ev.Command) void {
        switch (cmd) {
            .golive_start => |s| {
                if (g.voice_channel == 0 or g.me == 0) {
                    g.emit(.{ .golive = .{ .ended = .{ .watch = false, .user = g.me, .reason = .other } } });
                    return;
                }
                // Já transmitindo: encerra a anterior antes (o Discord só deixa uma).
                if (ls.out.key) |k| ls.send(g, golive_json.op_delete, k);
                ls.out.clear();
                const key: golive.Key = .{ .guild = s.guild, .channel = s.channel, .user = g.me };
                ls.out.key = key;
                var b: [256]u8 = undefined;
                if (golive_json.create(&b, s.guild, s.channel)) |p| _ = g.writeWs(p);
                if (golive_json.setPaused(&b, key, false)) |p| _ = g.writeWs(p);
                std.log.debug("golive: op 18 (canal {d})", .{s.channel});
            },
            .golive_stop => {
                if (ls.out.key) |k| ls.send(g, golive_json.op_delete, k);
                ls.out.clear();
            },
            .golive_watch => |wt| {
                if (ls.in.key) |k| ls.send(g, golive_json.op_delete, k);
                ls.in.clear();
                if (g.voice_channel == 0 or g.me == 0) return;
                const key: golive.Key = .{ .guild = wt.guild, .channel = wt.channel, .user = wt.user };
                ls.in.key = key;
                ls.send(g, golive_json.op_watch, key);
                std.log.debug("golive: op 20 ({d})", .{wt.user});
            },
            .golive_unwatch => {
                if (ls.in.key) |k| ls.send(g, golive_json.op_delete, k);
                ls.in.clear();
            },
            else => {},
        }
    }

    fn send(_: *Links, g: anytype, op: u8, key: golive.Key) void {
        var b: [160]u8 = undefined;
        if (golive_json.withKey(&b, op, key)) |p| _ = g.writeWs(p);
    }

    /// Eventos do gateway; true = era de transmissão.
    pub fn dispatch(ls: *Links, g: anytype, t: []const u8, d: Value) bool {
        if (std.mem.eql(u8, t, "STREAM_CREATE")) {
            const cr = golive_json.parseCreate(d) orelse return true;
            const l = ls.linkFor(cr.key) orelse return true;
            if (l.rtc != cr.rtc_server_id) l.kill();
            l.rtc = cr.rtc_server_id;
            ls.tryStart(g, l);
            return true;
        }
        if (std.mem.eql(u8, t, "STREAM_SERVER_UPDATE")) {
            const sv = golive_json.parseServer(d) orelse return true;
            const l = ls.linkFor(sv.key) orelse return true;
            // Servidor novo: a conexão atual não vale mais.
            l.kill();
            l.endpoint_len = 0;
            if (sv.endpoint) |ep| {
                l.endpoint_len = @min(ep.len, l.endpoint.len - 1);
                @memcpy(l.endpoint[0..l.endpoint_len], ep[0..l.endpoint_len]);
            }
            l.token_len = @min(sv.token.len, l.token.len - 1);
            @memcpy(l.token[0..l.token_len], sv.token[0..l.token_len]);
            ls.tryStart(g, l);
            return true;
        }
        if (std.mem.eql(u8, t, "STREAM_UPDATE")) {
            const key = golive.Key.parse(j.str(j.get(d, "stream_key")) orelse return true) orelse return true;
            if (ls.out.matches(key)) {
                const n: u32 = @intCast(j.array(j.get(d, "viewer_ids")).len);
                g.emit(.{ .golive = .{ .viewers = n } });
            }
            return true;
        }
        if (std.mem.eql(u8, t, "STREAM_DELETE")) {
            const del = golive_json.parseDelete(d) orelse return true;
            const reason: ev.GoliveReason = switch (del.reason) {
                .ended => .ended,
                .full => .full,
                .unauthorized => .unauthorized,
                .other => .other,
            };
            if (ls.out.matches(del.key)) {
                ls.out.clear();
                g.emit(.{ .golive = .{ .ended = .{ .watch = false, .user = del.key.user, .reason = reason } } });
            } else if (ls.in.matches(del.key)) {
                ls.in.clear();
                g.emit(.{ .golive = .{ .ended = .{ .watch = true, .user = del.key.user, .reason = reason } } });
            }
            return true;
        }
        return false;
    }

    fn linkFor(ls: *Links, key: golive.Key) ?*Link {
        if (ls.out.matches(key)) return &ls.out;
        if (ls.in.matches(key)) return &ls.in;
        return null;
    }

    /// Abre a conexão da transmissão quando há servidor, token e a sessão de voz.
    fn tryStart(ls: *Links, g: anytype, l: *Link) void {
        if (l.conn != null or l.rtc == 0 or l.endpoint_len == 0 or l.token_len == 0) return;
        if (g.voice_session_len == 0 or g.me == 0) return;
        const key = l.key orelse return;
        const vc = alloc.create(voice_mod.Voice) catch return;
        vc.* = voice_mod.Voice.init(
            g.sink,
            key.guild,
            key.channel,
            g.me,
            l.endpoint[0..l.endpoint_len],
            l.token[0..l.token_len],
            g.voice_session[0..g.voice_session_len],
            false,
            false,
        );
        const watching = l == &ls.in;
        vc.kind = if (watching) .stream_watch else .stream_send;
        vc.rtc_server_id = l.rtc;
        vc.stream_user = key.user;
        vc.start() catch {
            vc.deinit();
            alloc.destroy(vc);
            g.emit(.{ .golive = .{ .ended = .{ .watch = watching, .user = key.user, .reason = .other } } });
            l.clear();
            return;
        };
        l.conn = vc;
        std.log.debug("golive: conexão aberta ({s})", .{if (watching) "assistindo" else "transmitindo"});
    }

    /// A cada volta do gateway: conexão que acabou sozinha (o Discord fechou de
    /// vez) encerra a transmissão.
    pub fn tick(ls: *Links, g: anytype) void {
        inline for (.{ &ls.out, &ls.in }, .{ false, true }) |l, watching| {
            if (l.conn) |vc| switch (vc.ended.load(.acquire)) {
                .running => {},
                // 4014 numa transmissão: o servidor dela mudou; um STREAM_SERVER_UPDATE novo reabre.
                .moved => l.kill(),
                .fatal, .stopped => {
                    const key = l.key;
                    if (key) |k| ls.send(g, golive_json.op_delete, k);
                    l.clear();
                    g.emit(.{ .golive = .{ .ended = .{ .watch = watching, .user = if (key) |k| k.user else 0, .reason = .dropped } } });
                },
            };
        }
    }

    pub fn busy(ls: *const Links) bool {
        return ls.out.key != null or ls.in.key != null;
    }

    /// Saímos da call (ou a sessão caiu): nada de transmissão continua.
    pub fn stopAll(ls: *Links, g: anytype, tell: bool) void {
        inline for (.{ &ls.out, &ls.in }, .{ false, true }) |l, watching| {
            if (l.key) |k| {
                if (tell) ls.send(g, golive_json.op_delete, k);
                l.clear();
                g.emit(.{ .golive = .{ .ended = .{ .watch = watching, .user = k.user, .reason = .left } } });
            }
        }
    }

    pub fn deinit(ls: *Links) void {
        ls.out.clear();
        ls.in.clear();
        golive_media.setConsumer(false);
    }
};
