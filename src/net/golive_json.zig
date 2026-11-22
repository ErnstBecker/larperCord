//! Transmissão de tela: o que vai e o que vem do gateway principal e do gateway
//! de voz da transmissão, sem rede (testável).
//!
//! No gateway principal: op 18 abre a transmissão (STREAM_CREATE), op 22 diz que
//! ela não está pausada, op 19 encerra e op 20 pede para assistir. O Discord
//! responde com STREAM_CREATE (o `rtc_server_id`) e STREAM_SERVER_UPDATE (endereço
//! e token): a transmissão é uma conexão de voz à parte, com `server_id` =
//! `rtc_server_id` e a mesma sessão da call.
const std = @import("std");
const j = @import("jsonx.zig");
const golive = @import("../core/golive.zig");
const Id = u64;
const Value = std.json.Value;

fn idOrNull(buf: []u8, id: Id) []const u8 {
    if (id == 0) return "null";
    return std.fmt.bufPrint(buf, "\"{d}\"", .{id}) catch "null";
}

/// Op 18: abre a nossa transmissão na call em que estamos.
pub fn create(buf: []u8, guild: Id, channel: Id) ?[]const u8 {
    var gb: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{{\"op\":18,\"d\":{{\"type\":\"{s}\",\"guild_id\":{s},\"channel_id\":\"{d}\",\"preferred_region\":null}}}}", .{
        if (guild != 0) "guild" else "call", idOrNull(&gb, guild), channel,
    }) catch null;
}

/// Op 19 (encerra), 20 (assistir) e 22 (pausada ou não): só a chave.
pub fn withKey(buf: []u8, op: u8, key: golive.Key) ?[]const u8 {
    var kb: [96]u8 = undefined;
    const k = key.format(&kb) orelse return null;
    return std.fmt.bufPrint(buf, "{{\"op\":{d},\"d\":{{\"stream_key\":\"{s}\"}}}}", .{ op, k }) catch null;
}

pub fn setPaused(buf: []u8, key: golive.Key, paused: bool) ?[]const u8 {
    var kb: [96]u8 = undefined;
    const k = key.format(&kb) orelse return null;
    return std.fmt.bufPrint(buf, "{{\"op\":22,\"d\":{{\"stream_key\":\"{s}\",\"paused\":{s}}}}}", .{ k, if (paused) "true" else "false" }) catch null;
}

pub const op_delete: u8 = 19;
pub const op_watch: u8 = 20;

/// STREAM_CREATE: a transmissão existe e tem um servidor de mídia.
pub const Created = struct { key: golive.Key, rtc_server_id: Id, paused: bool = false };

pub fn parseCreate(d: Value) ?Created {
    const key = golive.Key.parse(j.str(j.get(d, "stream_key")) orelse return null) orelse return null;
    const rtc = j.id(j.get(d, "rtc_server_id")) orelse return null;
    const paused = if (j.get(d, "paused")) |p| p == .bool and p.bool else false;
    return .{ .key = key, .rtc_server_id = rtc, .paused = paused };
}

/// STREAM_SERVER_UPDATE: onde conectar (os textos apontam para dentro de `d`).
pub const Server = struct { key: golive.Key, endpoint: ?[]const u8, token: []const u8 };

pub fn parseServer(d: Value) ?Server {
    const key = golive.Key.parse(j.str(j.get(d, "stream_key")) orelse return null) orelse return null;
    const token = j.str(j.get(d, "token")) orelse return null;
    return .{ .key = key, .endpoint = j.str(j.get(d, "endpoint")), .token = token };
}

/// STREAM_DELETE: acabou. `reason` vem como "user_requested", "stream_full",
/// "unauthorized"…; `unavailable`: a transmissão sumiu sem a pessoa encerrar.
pub const Deleted = struct { key: golive.Key, reason: Reason };
pub const Reason = enum { ended, full, unauthorized, other };

pub fn parseDelete(d: Value) ?Deleted {
    const key = golive.Key.parse(j.str(j.get(d, "stream_key")) orelse return null) orelse return null;
    const r = j.str(j.get(d, "reason")) orelse "";
    const reason: Reason = if (r.len == 0 or std.mem.eql(u8, r, "user_requested") or std.mem.eql(u8, r, "stream_ended"))
        .ended
    else if (std.mem.eql(u8, r, "stream_full"))
        .full
    else if (std.mem.eql(u8, r, "unauthorized"))
        .unauthorized
    else
        .other;
    return .{ .key = key, .reason = reason };
}

// --- O gateway de voz da transmissão -------------------------------------------

/// Op 0: como o da call, com `server_id` = `rtc_server_id`, vídeo e a lista de
/// streams (uma tela, qualidade 100). O texto leva o token: quem chama apaga.
pub fn writeIdentify(out: *std.ArrayList(u8), a: std.mem.Allocator, rtc_server_id: Id, user: Id, session: []const u8, token: []const u8, max_dave: u16) !void {
    try out.print(a, "{{\"op\":0,\"d\":{{\"server_id\":\"{d}\",\"user_id\":\"{d}\",\"session_id\":", .{ rtc_server_id, user });
    try j.writeString(out, a, session);
    try out.appendSlice(a, ",\"token\":");
    try j.writeString(out, a, token);
    try out.print(a, ",\"video\":true,\"streams\":[{{\"type\":\"screen\",\"rid\":\"100\",\"quality\":100}}],\"max_dave_protocol_version\":{d}}}}}", .{max_dave});
}

pub fn writeResume(out: *std.ArrayList(u8), a: std.mem.Allocator, rtc_server_id: Id, session: []const u8, token: []const u8, seq_ack: i64) !void {
    try out.print(a, "{{\"op\":7,\"d\":{{\"server_id\":\"{d}\",\"session_id\":", .{rtc_server_id});
    try j.writeString(out, a, session);
    try out.appendSlice(a, ",\"token\":");
    try j.writeString(out, a, token);
    try out.print(a, ",\"seq_ack\":{d}}}}}", .{seq_ack});
}

/// O que sabemos fazer com cada codec de vídeo.
pub const CodecCaps = struct { codec: golive.Codec, encode: bool, decode: bool };

/// Op 1 com a lista de codecs: Opus e os vídeos que conseguimos receber ou mandar.
pub fn writeSelectProtocol(out: *std.ArrayList(u8), a: std.mem.Allocator, ip: []const u8, port: u16, mode: []const u8, caps: []const CodecCaps) !void {
    try out.appendSlice(a, "{\"op\":1,\"d\":{\"protocol\":\"udp\",\"codecs\":[{\"name\":\"opus\",\"type\":\"audio\",\"priority\":1000,\"payload_type\":120}");
    for (caps, 0..) |cp, i| {
        if (!cp.encode and !cp.decode) continue;
        const pt = cp.codec.payloadType();
        try out.print(a, ",{{\"name\":\"{s}\",\"type\":\"video\",\"priority\":{d},\"payload_type\":{d},\"rtx_payload_type\":{d},\"encode\":{s},\"decode\":{s}}}", .{
            cp.codec.name(),     1000 - @as(u32, @intCast(i)) * 100, pt,                                   pt + 1,
            flag(cp.encode), flag(cp.decode),
        });
    }
    try out.appendSlice(a, "],\"data\":{\"address\":");
    try j.writeString(out, a, ip);
    try out.print(a, ",\"port\":{d},\"mode\":", .{port});
    try j.writeString(out, a, mode);
    try out.appendSlice(a, "}}}");
}

fn flag(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Op 12: "este SSRC manda vídeo nesta resolução" (ou, `on` falso, parou).
pub fn writeVideo(buf: []u8, audio_ssrc: u32, video_ssrc: u32, rtx_ssrc: u32, on: bool, w: u32, h: u32, fps: u32, kbps: u32) ?[]const u8 {
    if (!on) return std.fmt.bufPrint(buf, "{{\"op\":12,\"d\":{{\"audio_ssrc\":{d},\"video_ssrc\":0,\"rtx_ssrc\":0,\"streams\":[]}}}}", .{audio_ssrc}) catch null;
    return std.fmt.bufPrint(buf, "{{\"op\":12,\"d\":{{\"audio_ssrc\":{d},\"video_ssrc\":{d},\"rtx_ssrc\":{d},\"streams\":[{{\"type\":\"video\",\"rid\":\"100\",\"ssrc\":{d},\"active\":true,\"quality\":100,\"rtx_ssrc\":{d},\"max_bitrate\":{d},\"max_framerate\":{d},\"max_resolution\":{{\"type\":\"fixed\",\"width\":{d},\"height\":{d}}}}}]}}}}", .{
        audio_ssrc, video_ssrc, rtx_ssrc, video_ssrc, rtx_ssrc, @as(u64, kbps) * 1000, fps, w, h,
    }) catch null;
}

/// Op 15: queremos o vídeo de todo mundo na qualidade máxima.
pub const sink_wants = "{\"op\":15,\"d\":{\"any\":100}}";

/// O READY da transmissão: o SSRC do áudio e, em `streams`, o do vídeo e do RTX.
pub const Ssrcs = struct { audio: u32 = 0, video: u32 = 0, rtx: u32 = 0 };

fn u32Of(v: ?Value) u32 {
    return @intCast(std.math.clamp(j.int(v) orelse 0, 0, std.math.maxInt(u32)));
}

pub fn readySsrcs(d: Value) Ssrcs {
    var s: Ssrcs = .{ .audio = u32Of(j.get(d, "ssrc")) };
    const streams = j.array(j.get(d, "streams"));
    if (streams.len > 0) {
        s.video = u32Of(j.get(streams[0], "ssrc"));
        s.rtx = u32Of(j.get(streams[0], "rtx_ssrc"));
    }
    // Sem a lista: o cliente oficial usa os dois seguintes.
    if (s.video == 0 and s.audio != 0) {
        s.video = s.audio +% 1;
        s.rtx = s.audio +% 2;
    }
    return s;
}

/// Op 12 vindo do servidor: de quem é cada SSRC de quem transmite.
pub const Remote = struct { user: Id, audio: u32, video: u32 };

pub fn parseVideo(d: Value) ?Remote {
    const user = j.id(j.get(d, "user_id")) orelse return null;
    var video = u32Of(j.get(d, "video_ssrc"));
    if (video == 0) for (j.array(j.get(d, "streams"))) |st| {
        const active = if (j.get(st, "active")) |a| a != .bool or a.bool else true;
        const s = u32Of(j.get(st, "ssrc"));
        if (active and s != 0) {
            video = s;
            break;
        }
    };
    return .{ .user = user, .audio = u32Of(j.get(d, "audio_ssrc")), .video = video };
}

/// O codec de vídeo da sessão (op 4 e op 14), se veio.
pub fn sessionCodec(d: Value) ?golive.Codec {
    return golive.Codec.ofName(j.str(j.get(d, "video_codec")) orelse return null);
}

// --- Testes ----------------------------------------------------------------

const t = std.testing;

fn parse(a: std.mem.Allocator, s: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, s, .{});
}

test "op 18, 19, 20 e 22" {
    var b: [256]u8 = undefined;
    try t.expectEqualStrings(
        "{\"op\":18,\"d\":{\"type\":\"guild\",\"guild_id\":\"42\",\"channel_id\":\"500014\",\"preferred_region\":null}}",
        create(&b, 42, 500014).?,
    );
    try t.expectEqualStrings(
        "{\"op\":18,\"d\":{\"type\":\"call\",\"guild_id\":null,\"channel_id\":\"900001\",\"preferred_region\":null}}",
        create(&b, 0, 900001).?,
    );
    const k: golive.Key = .{ .guild = 42, .channel = 500014, .user = 1000 };
    try t.expectEqualStrings("{\"op\":19,\"d\":{\"stream_key\":\"guild:42:500014:1000\"}}", withKey(&b, op_delete, k).?);
    try t.expectEqualStrings("{\"op\":20,\"d\":{\"stream_key\":\"call:9:7\"}}", withKey(&b, op_watch, .{ .channel = 9, .user = 7 }).?);
    try t.expectEqualStrings("{\"op\":22,\"d\":{\"stream_key\":\"guild:42:500014:1000\",\"paused\":false}}", setPaused(&b, k, false).?);
    var tiny: [16]u8 = undefined;
    try t.expect(create(&tiny, 1, 2) == null);
}

test "STREAM_CREATE, STREAM_SERVER_UPDATE e STREAM_DELETE" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = parseCreate(try parse(a, "{\"stream_key\":\"guild:42:500014:1000\",\"rtc_server_id\":\"1234567\",\"region\":\"brazil\",\"viewer_ids\":[],\"paused\":false}")).?;
    try t.expectEqual(@as(Id, 1234567), c.rtc_server_id);
    try t.expectEqual(@as(Id, 1000), c.key.user);
    try t.expect(parseCreate(try parse(a, "{\"stream_key\":\"x\",\"rtc_server_id\":\"1\"}")) == null);
    const s = parseServer(try parse(a, "{\"stream_key\":\"call:9:7\",\"endpoint\":\"brazil1234.discord.media:443\",\"token\":\"abc\",\"guild_id\":null}")).?;
    try t.expectEqualStrings("brazil1234.discord.media:443", s.endpoint.?);
    try t.expectEqualStrings("abc", s.token);
    try t.expectEqual(@as(Id, 9), s.key.channel);
    const s2 = parseServer(try parse(a, "{\"stream_key\":\"call:9:7\",\"endpoint\":null,\"token\":\"abc\"}")).?;
    try t.expect(s2.endpoint == null);
    try t.expectEqual(Reason.full, parseDelete(try parse(a, "{\"stream_key\":\"call:9:7\",\"reason\":\"stream_full\",\"unavailable\":false}")).?.reason);
    try t.expectEqual(Reason.ended, parseDelete(try parse(a, "{\"stream_key\":\"call:9:7\",\"reason\":\"user_requested\"}")).?.reason);
    try t.expectEqual(Reason.other, parseDelete(try parse(a, "{\"stream_key\":\"call:9:7\",\"reason\":\"unavailable\"}")).?.reason);
}

test "IDENTIFY, RESUME e Select Protocol da transmissão" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeIdentify(&out, a, 1234567, 1000, "sess", "tk", 1);
    try t.expectEqualStrings(
        "{\"op\":0,\"d\":{\"server_id\":\"1234567\",\"user_id\":\"1000\",\"session_id\":\"sess\",\"token\":\"tk\",\"video\":true,\"streams\":[{\"type\":\"screen\",\"rid\":\"100\",\"quality\":100}],\"max_dave_protocol_version\":1}}",
        out.items,
    );
    out.clearRetainingCapacity();
    try writeResume(&out, a, 1234567, "s", "t", 3);
    try t.expectEqualStrings("{\"op\":7,\"d\":{\"server_id\":\"1234567\",\"session_id\":\"s\",\"token\":\"t\",\"seq_ack\":3}}", out.items);
    out.clearRetainingCapacity();
    try writeSelectProtocol(&out, a, "1.2.3.4", 5000, "aead_xchacha20_poly1305_rtpsize", &.{
        .{ .codec = .h264, .encode = true, .decode = true },
        .{ .codec = .vp8, .encode = false, .decode = true },
        .{ .codec = .av1, .encode = false, .decode = false },
    });
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), out.items);
    const d = j.get(v, "d").?;
    const codecs = j.array(j.get(d, "codecs"));
    try t.expectEqual(@as(usize, 3), codecs.len); // opus, H264, VP8 (o AV1 ficou de fora)
    try t.expectEqualStrings("H264", j.str(j.get(codecs[1], "name")).?);
    try t.expectEqual(@as(i64, 102), j.int(j.get(codecs[1], "rtx_payload_type")).?);
    try t.expect(j.get(codecs[2], "encode").?.bool == false);
    try t.expectEqualStrings("aead_xchacha20_poly1305_rtpsize", j.str(j.get(j.get(d, "data").?, "mode")).?);
    try t.expectEqual(@as(i64, 5000), j.int(j.get(j.get(d, "data").?, "port")).?);
}

test "op 12 e o READY da transmissão" {
    var b: [512]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const on = try parse(a, writeVideo(&b, 10, 11, 12, true, 1280, 720, 30, 2500).?);
    const d = j.get(on, "d").?;
    try t.expectEqual(@as(i64, 11), j.int(j.get(d, "video_ssrc")).?);
    const st = j.array(j.get(d, "streams"))[0];
    try t.expectEqual(@as(i64, 2_500_000), j.int(j.get(st, "max_bitrate")).?);
    try t.expectEqual(@as(i64, 720), j.int(j.get(j.get(st, "max_resolution").?, "height")).?);
    const off = try parse(a, writeVideo(&b, 10, 11, 12, false, 0, 0, 0, 0).?);
    try t.expectEqual(@as(usize, 0), j.array(j.get(j.get(off, "d").?, "streams")).len);
    const r = readySsrcs(try parse(a, "{\"ssrc\":100,\"ip\":\"1.2.3.4\",\"port\":1,\"streams\":[{\"type\":\"video\",\"ssrc\":101,\"rtx_ssrc\":102,\"rid\":\"100\"}]}"));
    try t.expectEqual(Ssrcs{ .audio = 100, .video = 101, .rtx = 102 }, r);
    try t.expectEqual(Ssrcs{ .audio = 7, .video = 8, .rtx = 9 }, readySsrcs(try parse(a, "{\"ssrc\":7}")));
    const rem = parseVideo(try parse(a, "{\"user_id\":\"55\",\"audio_ssrc\":200,\"video_ssrc\":0,\"streams\":[{\"ssrc\":0,\"active\":false},{\"ssrc\":201,\"active\":true}]}")).?;
    try t.expectEqual(Remote{ .user = 55, .audio = 200, .video = 201 }, rem);
    try t.expectEqual(golive.Codec.h264, sessionCodec(try parse(a, "{\"video_codec\":\"H264\",\"audio_codec\":\"opus\"}")).?);
}
