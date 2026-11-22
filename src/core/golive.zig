//! Transmissão de tela (o "Go Live" do Discord), a parte sem rede nem FFmpeg:
//! a chave da transmissão, o RTP do vídeo (H.264 em FU-A/STAP-A, VP8) e os
//! pacotes de RTCP que pedem e anunciam quadros. Tudo testável.
//!
//! O vídeo sai do codificador em Annex B (cada NAL depois de 00 00 01 ou
//! 00 00 00 01). Com o DAVE ligado, o quadro é cifrado inteiro antes de virar
//! pacotes e o libdave escreve sempre o código de início de 4 bytes; quem
//! recebe remonta com 4 bytes também, senão os trechos em claro que o DAVE
//! autentica não batem. A divisão em NALs segue a do WebRTC e a do libdave
//! (`FindNextH26XNaluIndex`): só um zero antes de 00 00 01 faz parte do código.
const std = @import("std");
/// O mesmo que `types.Id` (sem importar o resto: este arquivo se testa sozinho).
const Id = u64;

// --- A chave da transmissão --------------------------------------------------

/// `guild:<servidor>:<canal>:<pessoa>` ou, numa DM ou grupo, `call:<canal>:<pessoa>`.
pub const Key = struct {
    guild: Id = 0,
    channel: Id,
    user: Id,

    pub fn format(k: Key, buf: []u8) ?[]const u8 {
        return if (k.guild != 0)
            std.fmt.bufPrint(buf, "guild:{d}:{d}:{d}", .{ k.guild, k.channel, k.user }) catch null
        else
            std.fmt.bufPrint(buf, "call:{d}:{d}", .{ k.channel, k.user }) catch null;
    }

    pub fn parse(s: []const u8) ?Key {
        var it = std.mem.splitScalar(u8, s, ':');
        const kind = it.next() orelse return null;
        var k: Key = .{ .channel = 0, .user = 0 };
        if (std.mem.eql(u8, kind, "guild")) {
            k.guild = std.fmt.parseInt(Id, it.next() orelse return null, 10) catch return null;
        } else if (!std.mem.eql(u8, kind, "call")) return null;
        k.channel = std.fmt.parseInt(Id, it.next() orelse return null, 10) catch return null;
        k.user = std.fmt.parseInt(Id, it.next() orelse return null, 10) catch return null;
        if (it.next() != null or k.channel == 0 or k.user == 0) return null;
        return k;
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.guild == b.guild and a.channel == b.channel and a.user == b.user;
    }
};

/// O grupo do DAVE de uma transmissão: o `rtc_server_id` menos um (o cliente
/// oficial usa o "canal" da transmissão, que vem logo antes do servidor dela).
pub fn daveGroup(rtc_server_id: Id) Id {
    return rtc_server_id -% 1;
}

// --- Codecs ------------------------------------------------------------------

pub const Codec = enum(u8) {
    h264,
    vp8,
    h265,
    vp9,
    av1,

    /// Tipos de payload que o cliente oficial anuncia (o RTX é o seguinte).
    pub fn payloadType(cd: Codec) u8 {
        return switch (cd) {
            .h264 => 101,
            .h265 => 103,
            .vp8 => 105,
            .vp9 => 107,
            .av1 => 109,
        };
    }

    pub fn ofPayloadType(pt: u8) ?Codec {
        return switch (pt) {
            101 => .h264,
            103 => .h265,
            105 => .vp8,
            107 => .vp9,
            109 => .av1,
            else => null,
        };
    }

    /// O nome que o Discord usa (`video_codec` e a lista do Select Protocol).
    pub fn name(cd: Codec) []const u8 {
        return switch (cd) {
            .h264 => "H264",
            .h265 => "H265",
            .vp8 => "VP8",
            .vp9 => "VP9",
            .av1 => "AV1",
        };
    }

    pub fn ofName(s: []const u8) ?Codec {
        for (std.enums.values(Codec)) |cd| {
            if (std.ascii.eqlIgnoreCase(s, cd.name())) return cd;
        }
        return null;
    }
};

/// O relógio do RTP de vídeo.
pub const clock_hz: u32 = 90_000;
/// Carga máxima de um pacote de vídeo: cabe com folga no MTU comum depois do
/// cabeçalho, da extensão, da etiqueta do AEAD e de uma VPN no caminho.
pub const max_payload: usize = 1100;

// --- NALs (Annex B) ----------------------------------------------------------

/// Onde começa o próximo NAL a partir de `from`: o índice do primeiro byte dele e
/// o tamanho do código de início (3 ou 4) que vem antes.
pub fn nextNal(buf: []const u8, from: usize) ?struct { start: usize, code: usize } {
    // Como o libdave: o código de início precisa de pelo menos um byte depois dele.
    if (buf.len < 4) return null;
    var i = from;
    while (i < buf.len - 3) {
        if (buf[i + 2] > 1) {
            i += 3;
        } else if (buf[i + 2] == 1) {
            if (buf[i] == 0 and buf[i + 1] == 0) {
                const four = i >= 1 and buf[i - 1] == 0;
                return .{ .start = i + 3, .code = if (four) 4 else 3 };
            }
            i += 3;
        } else i += 1;
    }
    return null;
}

/// Cada NAL de um quadro, sem o código de início.
pub const Nals = struct {
    buf: []const u8,
    next: ?usize,

    pub fn init(buf: []const u8) Nals {
        return .{ .buf = buf, .next = if (nextNal(buf, 0)) |n| n.start else null };
    }

    pub fn nextUnit(it: *Nals) ?[]const u8 {
        const start = it.next orelse return null;
        if (start >= it.buf.len) {
            it.next = null;
            return null;
        }
        if (nextNal(it.buf, start)) |n| {
            it.next = n.start;
            return it.buf[start .. n.start - n.code];
        }
        it.next = null;
        return it.buf[start..];
    }
};

/// O quadro tem um IDR (quadro-chave do H.264)?
pub fn h264Keyframe(frame: []const u8) bool {
    var it = Nals.init(frame);
    while (it.nextUnit()) |nal| {
        if (nal.len > 0 and nal[0] & 0x1f == 5) return true;
    }
    return false;
}

// --- Empacotar ---------------------------------------------------------------

/// Divide um quadro H.264 em cargas de RTP: NAL pequeno vai inteiro, grande vai
/// em FU-A. `sink.packet(prefix, body, marker)`: a carga é `prefix ++ body`, e o
/// marcador fecha o quadro (o último pedaço do último NAL).
pub fn packetizeH264(frame: []const u8, max: usize, sink: anytype) usize {
    var count: usize = 0;
    var it = Nals.init(frame);
    var cur = it.nextUnit();
    while (cur) |nal| {
        const nxt = it.nextUnit();
        const last_nal = nxt == null;
        cur = nxt;
        if (nal.len == 0) continue;
        if (nal.len <= max) {
            sink.packet(&.{}, nal, last_nal);
            count += 1;
            continue;
        }
        const indicator: u8 = (nal[0] & 0xe0) | 28;
        const typ: u8 = nal[0] & 0x1f;
        var off: usize = 1;
        const room = max - 2;
        while (off < nal.len) {
            const n = @min(room, nal.len - off);
            const first = off == 1;
            const end = off + n == nal.len;
            const header: u8 = typ | (if (first) @as(u8, 0x80) else 0) | (if (end) @as(u8, 0x40) else 0);
            const prefix = [2]u8{ indicator, header };
            sink.packet(&prefix, nal[off .. off + n], end and last_nal);
            count += 1;
            off += n;
        }
    }
    return count;
}

/// VP8 (RFC 7741): o descritor com o número da imagem (15 bits) na frente de cada
/// pedaço; S no primeiro.
pub fn packetizeVp8(frame: []const u8, max: usize, picture_id: u15, sink: anytype) usize {
    var count: usize = 0;
    var off: usize = 0;
    const room = max - 4;
    while (off < frame.len) {
        const n = @min(room, frame.len - off);
        const first = off == 0;
        const prefix = [4]u8{
            0x80 | (if (first) @as(u8, 0x10) else 0), // X, S (partição 0)
            0x80, // I: tem o número da imagem
            0x80 | @as(u8, @intCast(picture_id >> 8)), // M: 15 bits
            @truncate(picture_id),
        };
        sink.packet(&prefix, frame[off .. off + n], off + n == frame.len);
        count += 1;
        off += n;
    }
    return count;
}

/// VP8: quadro-chave pelo bit P do primeiro byte (0 = chave).
pub fn vp8Keyframe(frame: []const u8) bool {
    return frame.len > 0 and frame[0] & 1 == 0;
}

// --- Cabeçalho RTP -----------------------------------------------------------

/// Bytes do cabeçalho de vídeo com a extensão: 12 fixos + 4 do 0xBEDE.
pub const header_len = 16;
/// O corpo da extensão (vai cifrado, colado na frente da carga): playout-delay
/// (id 5, 3 bytes, mínimo e máximo 0), como os clientes que transmitem.
pub const ext_body = [4]u8{ 0x52, 0, 0, 0 };

pub fn writeHeader(out: *[header_len]u8, pt: u8, marker: bool, seq: u16, ts: u32, ssrc: u32) void {
    out[0] = 0x90; // versão 2, com extensão
    out[1] = pt | (if (marker) @as(u8, 0x80) else 0);
    std.mem.writeInt(u16, out[2..4], seq, .big);
    std.mem.writeInt(u32, out[4..8], ts, .big);
    std.mem.writeInt(u32, out[8..12], ssrc, .big);
    out[12] = 0xBE;
    out[13] = 0xDE;
    std.mem.writeInt(u16, out[14..16], ext_body.len / 4, .big);
}

// --- Remontar ----------------------------------------------------------------

/// Um quadro remontado. `loss`: algo antes dele se perdeu (quem decodifica espera
/// um quadro-chave e pede um).
pub const Frame = struct { data: []const u8, ts: u32, loss: bool };

const Part = struct { seq: u16, off: u32, len: u32, marker: bool };

/// Junta os pacotes de vídeo de um mesmo instante (o timestamp do RTP) num quadro
/// inteiro, mesmo fora de ordem. Pacote atrasado de um quadro já fechado fica de fora;
/// faltando pedaço quando o próximo quadro começa, o incompleto é descartado e o
/// próximo sai marcado com `loss`.
pub const Assembler = struct {
    codec: Codec = .h264,
    ts: u32 = 0,
    active: bool = false,
    parts: std.ArrayList(Part) = .empty,
    pool: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// O último pacote do último quadro entregue (ou descartado).
    last_seq: ?u16 = null,
    last_ts: ?u32 = null,
    /// Perdemos algo desde o último quadro entregue.
    lost: bool = false,
    /// Quadros descartados por falta de pedaço (diagnóstico e QA).
    dropped: u32 = 0,

    pub fn deinit(a: *Assembler, gpa: std.mem.Allocator) void {
        a.parts.deinit(gpa);
        a.pool.deinit(gpa);
        a.out.deinit(gpa);
    }

    pub fn reset(a: *Assembler) void {
        a.active = false;
        a.parts.clearRetainingCapacity();
        a.pool.clearRetainingCapacity();
        a.last_seq = null;
        a.last_ts = null;
        a.lost = false;
    }

    fn newer(x: u32, than: u32) bool {
        return @as(i32, @bitCast(x -% than)) > 0;
    }

    fn seqAfter(x: u16, than: u16) bool {
        return @as(i16, @bitCast(x -% than)) > 0;
    }

    /// Um pacote (a carga já decifrada, sem o corpo da extensão). Devolve o quadro
    /// quando ele fecha; os bytes valem até a próxima chamada.
    pub fn push(a: *Assembler, gpa: std.mem.Allocator, seq: u16, ts: u32, marker: bool, payload: []const u8) ?Frame {
        if (payload.len == 0) return null;
        if (a.last_ts) |lt| if (!newer(ts, lt)) return null; // quadro já fechado
        if (a.active and ts != a.ts) {
            if (!newer(ts, a.ts)) return null; // de um quadro que já abandonamos
            // Começou outro sem o atual fechar: falta pedaço.
            a.abandon();
        }
        if (!a.active) {
            a.active = true;
            a.ts = ts;
            a.parts.clearRetainingCapacity();
            a.pool.clearRetainingCapacity();
        }
        // Na ordem da sequência (quase sempre vai no fim).
        var at = a.parts.items.len;
        while (at > 0) {
            const p = a.parts.items[at - 1];
            if (p.seq == seq) return null; // repetido
            if (seqAfter(seq, p.seq)) break;
            at -= 1;
        }
        if (a.parts.items.len >= 4096 or a.pool.items.len + payload.len > 8 << 20) {
            a.abandon();
            return null;
        }
        const off: u32 = @intCast(a.pool.items.len);
        a.pool.appendSlice(gpa, payload) catch return null;
        a.parts.insert(gpa, at, .{ .seq = seq, .off = off, .len = @intCast(payload.len), .marker = marker }) catch return null;
        return a.tryFinish(gpa);
    }

    fn abandon(a: *Assembler) void {
        if (a.active) {
            a.dropped += 1;
            a.lost = true;
            if (a.parts.items.len > 0) a.last_seq = a.parts.items[a.parts.items.len - 1].seq;
            a.last_ts = a.ts;
        }
        a.active = false;
        a.parts.clearRetainingCapacity();
        a.pool.clearRetainingCapacity();
    }

    fn startsFrame(a: *const Assembler, p: Part) bool {
        const b = a.pool.items[p.off..][0..p.len];
        return switch (a.codec) {
            .h264 => switch (b[0] & 0x1f) {
                1...24 => true,
                28 => b.len >= 2 and b[1] & 0x80 != 0,
                else => false,
            },
            .vp8 => vp8Start(b),
            else => true,
        };
    }

    fn tryFinish(a: *Assembler, gpa: std.mem.Allocator) ?Frame {
        const ps = a.parts.items;
        if (ps.len == 0 or !ps[ps.len - 1].marker) return null;
        for (ps[1..], 0..) |p, i| if (p.seq != ps[i].seq +% 1) return null;
        if (!a.startsFrame(ps[0])) return null;
        // Algo sumiu entre o quadro anterior e este?
        var loss = a.lost;
        if (a.last_seq) |ls| if (ps[0].seq != ls +% 1) {
            loss = true;
        };
        a.out.clearRetainingCapacity();
        const ok = switch (a.codec) {
            .h264 => a.buildH264(gpa),
            .vp8 => a.buildVp8(gpa),
            else => a.buildRaw(gpa),
        };
        a.last_seq = ps[ps.len - 1].seq;
        a.last_ts = a.ts;
        a.active = false;
        a.parts.clearRetainingCapacity();
        a.pool.clearRetainingCapacity();
        if (!ok or a.out.items.len == 0) {
            a.dropped += 1;
            a.lost = true;
            return null;
        }
        a.lost = false;
        return .{ .data = a.out.items, .ts = a.ts, .loss = loss };
    }

    const start_code = [4]u8{ 0, 0, 0, 1 };

    fn buildH264(a: *Assembler, gpa: std.mem.Allocator) bool {
        var in_fu = false;
        for (a.parts.items) |p| {
            const b = a.pool.items[p.off..][0..p.len];
            const typ = b[0] & 0x1f;
            switch (typ) {
                1...23 => {
                    if (in_fu) return false;
                    a.out.appendSlice(gpa, &start_code) catch return false;
                    a.out.appendSlice(gpa, b) catch return false;
                },
                24 => {
                    if (in_fu) return false;
                    var i: usize = 1;
                    while (i + 2 <= b.len) {
                        const n = std.mem.readInt(u16, b[i..][0..2], .big);
                        i += 2;
                        if (n == 0 or i + n > b.len) return false;
                        a.out.appendSlice(gpa, &start_code) catch return false;
                        a.out.appendSlice(gpa, b[i .. i + n]) catch return false;
                        i += n;
                    }
                },
                28 => {
                    if (b.len < 2) return false;
                    const s = b[1] & 0x80 != 0;
                    const e = b[1] & 0x40 != 0;
                    if (s) {
                        if (in_fu) return false;
                        a.out.appendSlice(gpa, &start_code) catch return false;
                        a.out.append(gpa, (b[0] & 0xe0) | (b[1] & 0x1f)) catch return false;
                        in_fu = true;
                    } else if (!in_fu) return false;
                    a.out.appendSlice(gpa, b[2..]) catch return false;
                    if (e) in_fu = false;
                },
                else => {},
            }
        }
        return !in_fu;
    }

    fn buildVp8(a: *Assembler, gpa: std.mem.Allocator) bool {
        for (a.parts.items) |p| {
            const b = a.pool.items[p.off..][0..p.len];
            const skip = vp8DescriptorLen(b) orelse return false;
            a.out.appendSlice(gpa, b[skip..]) catch return false;
        }
        return true;
    }

    fn buildRaw(a: *Assembler, gpa: std.mem.Allocator) bool {
        for (a.parts.items) |p| a.out.appendSlice(gpa, a.pool.items[p.off..][0..p.len]) catch return false;
        return true;
    }
};

/// O tamanho do descritor VP8 (RFC 7741 §4.2) na frente da carga.
pub fn vp8DescriptorLen(b: []const u8) ?usize {
    if (b.len < 1) return null;
    var i: usize = 1;
    if (b[0] & 0x80 != 0) {
        if (b.len < 2) return null;
        const x = b[1];
        i = 2;
        if (x & 0x80 != 0) {
            if (b.len <= i) return null;
            i += if (b[i] & 0x80 != 0) 2 else 1;
        }
        if (x & 0x40 != 0) i += 1;
        if (x & 0x30 != 0) i += 1;
    }
    return if (i < b.len) i else null;
}

fn vp8Start(b: []const u8) bool {
    // S = 1 e partição 0.
    return b.len > 0 and b[0] & 0x10 != 0 and b[0] & 0x0f == 0;
}

// --- RTCP --------------------------------------------------------------------

pub fn isRtcp(pkt: []const u8) bool {
    return pkt.len >= 8 and pkt[0] >> 6 == 2 and pkt[1] >= 192 and pkt[1] <= 223;
}

/// PLI (RFC 4585): "mande um quadro-chave de `media`". 12 bytes; nos modos
/// "rtpsize" os 8 primeiros vão em claro.
pub fn pli(out: *[12]u8, sender: u32, media: u32) void {
    out[0] = 0x81;
    out[1] = 206;
    std.mem.writeInt(u16, out[2..4], 2, .big);
    std.mem.writeInt(u32, out[4..8], sender, .big);
    std.mem.writeInt(u32, out[8..12], media, .big);
}

/// Sender Report (RFC 3550): diz a quem recebe que relógio de parede corresponde ao
/// relógio do RTP, e quanto já saiu.
pub fn senderReport(out: *[28]u8, ssrc: u32, wall_ms: i64, rtp_ts: u32, packets: u32, octets: u32) void {
    out[0] = 0x80;
    out[1] = 200;
    std.mem.writeInt(u16, out[2..4], 6, .big);
    std.mem.writeInt(u32, out[4..8], ssrc, .big);
    // NTP: segundos desde 1900 e a fração.
    const ms: u64 = @intCast(@max(wall_ms, 0));
    const secs: u64 = ms / 1000 + 2_208_988_800;
    const frac: u64 = ((ms % 1000) << 32) / 1000;
    std.mem.writeInt(u32, out[8..12], @truncate(secs), .big);
    std.mem.writeInt(u32, out[12..16], @truncate(frac), .big);
    std.mem.writeInt(u32, out[16..20], rtp_ts, .big);
    std.mem.writeInt(u32, out[20..24], packets, .big);
    std.mem.writeInt(u32, out[24..28], octets, .big);
}

/// Pedem um quadro-chave de `media` neste RTCP (já decifrado, cabeçalho incluído)?
/// PLI (206/1) ou FIR (206/4), num pacote composto.
pub fn wantsKeyframe(pkt: []const u8, media: u32) bool {
    var i: usize = 0;
    while (i + 4 <= pkt.len) {
        const fmt = pkt[i] & 0x1f;
        const pt = pkt[i + 1];
        const words = std.mem.readInt(u16, pkt[i + 2 ..][0..2], .big);
        const end = i + (@as(usize, words) + 1) * 4;
        if (end > pkt.len) return false;
        if (pt == 206 and fmt == 1 and end - i >= 12) {
            if (std.mem.readInt(u32, pkt[i + 8 ..][0..4], .big) == media) return true;
        }
        if (pt == 206 and fmt == 4 and end - i >= 20) {
            // FIR: os pedidos vêm depois (ssrc + número), a partir do byte 12.
            var k = i + 12;
            while (k + 8 <= end) : (k += 8) {
                if (std.mem.readInt(u32, pkt[k..][0..4], .big) == media) return true;
            }
        }
        i = end;
    }
    return false;
}

// --- Qualidade ---------------------------------------------------------------

/// O que se escolhe ao começar a transmitir.
pub const Quality = enum(u8) {
    p720_30,
    p1080_30,
    p720_60,
    p480_15,

    pub fn height(q: Quality) u32 {
        return switch (q) {
            .p480_15 => 480,
            .p720_30, .p720_60 => 720,
            .p1080_30 => 1080,
        };
    }

    pub fn fps(q: Quality) u32 {
        return switch (q) {
            .p480_15 => 15,
            .p720_30, .p1080_30 => 30,
            .p720_60 => 60,
        };
    }

    /// kbit/s alvo (o teto do Discord sem Nitro fica bem acima).
    pub fn kbps(q: Quality) u32 {
        return switch (q) {
            .p480_15 => 900,
            .p720_30 => 2500,
            .p720_60 => 4000,
            .p1080_30 => 4500,
        };
    }

    pub fn label(q: Quality) []const u8 {
        return switch (q) {
            .p480_15 => "480p 15",
            .p720_30 => "720p 30",
            .p720_60 => "720p 60",
            .p1080_30 => "1080p 30",
        };
    }
};

/// O tamanho de saída para uma tela `w`×`h` cabendo na altura da qualidade, sem
/// aumentar e com lados pares (o YUV 4:2:0 pede).
pub fn fitSize(w: u32, h: u32, max_h: u32) [2]u32 {
    if (w == 0 or h == 0) return .{ 0, 0 };
    var ow = w;
    var oh = h;
    if (h > max_h) {
        oh = max_h;
        ow = @intCast((@as(u64, w) * max_h + h / 2) / h);
    }
    // E a largura também não passa de 16:9 da altura (telas ultralargas).
    const max_w = (max_h * 16 + 8) / 9 * 2;
    if (ow > max_w) {
        oh = @intCast((@as(u64, oh) * max_w + ow / 2) / ow);
        ow = max_w;
    }
    return .{ @max(ow & ~@as(u32, 1), 2), @max(oh & ~@as(u32, 1), 2) };
}

// --- Testes ------------------------------------------------------------------

const t = std.testing;

test "chave da transmissão: servidor e DM, ida e volta" {
    var b: [96]u8 = undefined;
    const g: Key = .{ .guild = 81384788765712384, .channel = 500014, .user = 1000 };
    try t.expectEqualStrings("guild:81384788765712384:500014:1000", g.format(&b).?);
    try t.expect(Key.parse("guild:81384788765712384:500014:1000").?.eql(g));
    const dm: Key = .{ .channel = 900001, .user = 7 };
    try t.expectEqualStrings("call:900001:7", dm.format(&b).?);
    try t.expect(Key.parse("call:900001:7").?.eql(dm));
    try t.expect(Key.parse("call:900001") == null);
    try t.expect(Key.parse("guild:1:2:3:4") == null);
    try t.expect(Key.parse("voice:1:2") == null);
    try t.expect(Key.parse("call:x:2") == null);
    try t.expectEqual(@as(Id, 41), daveGroup(42));
}

test "codecs: tipo de payload e nome" {
    try t.expectEqual(@as(u8, 101), Codec.h264.payloadType());
    try t.expectEqual(Codec.vp8, Codec.ofPayloadType(105).?);
    try t.expect(Codec.ofPayloadType(102) == null); // RTX
    try t.expectEqual(Codec.h264, Codec.ofName("h264").?);
    try t.expectEqualStrings("AV1", Codec.av1.name());
}

test "NALs: códigos de 3 e 4 bytes, como o WebRTC" {
    const f = [_]u8{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9 };
    var it = Nals.init(&f);
    try t.expectEqualSlices(u8, &.{ 0x67, 1, 2 }, it.nextUnit().?);
    try t.expectEqualSlices(u8, &.{ 0x68, 3 }, it.nextUnit().?);
    try t.expectEqualSlices(u8, &.{ 0x65, 9, 9 }, it.nextUnit().?);
    try t.expect(it.nextUnit() == null);
    try t.expect(h264Keyframe(&f));
    // Um zero no fim do NAL (texto cifrado do DAVE) não some: só um zero é do código.
    const g = [_]u8{ 0, 0, 0, 1, 0x41, 7, 0, 0, 0, 0, 1, 0x41, 8 };
    var it2 = Nals.init(&g);
    try t.expectEqualSlices(u8, &.{ 0x41, 7, 0 }, it2.nextUnit().?);
    try t.expectEqualSlices(u8, &.{ 0x41, 8 }, it2.nextUnit().?);
    try t.expect(!h264Keyframe(&g));
}

const Collect = struct {
    pkts: std.ArrayList([]u8) = .empty,
    markers: std.ArrayList(bool) = .empty,

    fn packet(cl: *Collect, prefix: []const u8, body: []const u8, marker: bool) void {
        const p = t.allocator.alloc(u8, prefix.len + body.len) catch unreachable;
        @memcpy(p[0..prefix.len], prefix);
        @memcpy(p[prefix.len..], body);
        cl.pkts.append(t.allocator, p) catch unreachable;
        cl.markers.append(t.allocator, marker) catch unreachable;
    }

    fn deinit(cl: *Collect) void {
        for (cl.pkts.items) |p| t.allocator.free(p);
        cl.pkts.deinit(t.allocator);
        cl.markers.deinit(t.allocator);
    }
};

fn testFrame(buf: []u8, big: usize) []u8 {
    // SPS, PPS e um IDR grande (vira FU-A), com códigos de 4 bytes como o DAVE escreve.
    var n: usize = 0;
    for ([_][]const u8{ &.{ 0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x1f }, &.{ 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80 }, &.{ 0, 0, 0, 1, 0x65 } }) |s| {
        @memcpy(buf[n..][0..s.len], s);
        n += s.len;
    }
    for (0..big) |i| {
        buf[n] = @intCast(2 + i % 200);
        n += 1;
    }
    return buf[0..n];
}

test "H.264: empacota e remonta igual, fora de ordem" {
    var fb: [6000]u8 = undefined;
    const frame = testFrame(&fb, 5000);
    var col: Collect = .{};
    defer col.deinit();
    const n = packetizeH264(frame, 1100, &col);
    try t.expect(n == 2 + 5); // SPS, PPS e 5 FU-A
    for (col.pkts.items) |p| try t.expect(p.len <= 1100);
    for (col.markers.items, 0..) |m, i| try t.expectEqual(i == n - 1, m);
    try t.expectEqual(@as(u8, 28), col.pkts.items[2][0] & 0x1f);
    try t.expectEqual(@as(u8, 0x85), col.pkts.items[2][1]); // S + IDR
    try t.expectEqual(@as(u8, 0x45), col.pkts.items[n - 1][1]); // E + IDR

    var asm_: Assembler = .{};
    defer asm_.deinit(t.allocator);
    // A ordem trocada no meio não importa.
    const order = [_]usize{ 0, 1, 3, 2, 4, 6, 5 };
    var got: ?Frame = null;
    for (order) |i| {
        if (asm_.push(t.allocator, 100 + @as(u16, @intCast(i)), 9000, col.markers.items[i], col.pkts.items[i])) |f| got = f;
    }
    try t.expect(got != null);
    try t.expectEqualSlices(u8, frame, got.?.data);
    try t.expect(!got.?.loss);
    try t.expect(h264Keyframe(got.?.data));
    // Pacote repetido ou de um quadro já fechado: nada.
    try t.expect(asm_.push(t.allocator, 101, 9000, false, col.pkts.items[1]) == null);
}

test "H.264: pedaço perdido descarta o quadro e marca o próximo" {
    var fb: [6000]u8 = undefined;
    const frame = testFrame(&fb, 3000);
    var col: Collect = .{};
    defer col.deinit();
    const n = packetizeH264(frame, 1100, &col);
    var asm_: Assembler = .{};
    defer asm_.deinit(t.allocator);
    var seq: u16 = 65530; // passa da volta do u16 no meio
    // Primeiro quadro sem o pacote 3.
    for (0..n) |i| {
        if (i != 3) try t.expect(asm_.push(t.allocator, seq, 1000, col.markers.items[i], col.pkts.items[i]) == null);
        seq +%= 1;
    }
    // O segundo, inteiro: sai, marcado com perda.
    var got: ?Frame = null;
    for (0..n) |i| {
        if (asm_.push(t.allocator, seq, 4000, col.markers.items[i], col.pkts.items[i])) |f| got = f;
        seq +%= 1;
    }
    try t.expect(got != null and got.?.loss);
    try t.expectEqual(@as(u32, 1), asm_.dropped);
    // O terceiro já sai limpo.
    got = null;
    for (0..n) |i| {
        if (asm_.push(t.allocator, seq, 7000, col.markers.items[i], col.pkts.items[i])) |f| got = f;
        seq +%= 1;
    }
    try t.expect(got != null and !got.?.loss);
    try t.expectEqualSlices(u8, frame, got.?.data);
}

test "H.264: STAP-A vira NALs separados" {
    const stap = [_]u8{ 24, 0, 3, 0x67, 1, 2, 0, 2, 0x68, 3 };
    var asm_: Assembler = .{};
    defer asm_.deinit(t.allocator);
    const f = asm_.push(t.allocator, 1, 10, true, &stap).?;
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3 }, f.data);
}

test "VP8: empacota e remonta" {
    var frame: [2500]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @truncate(i * 7);
    frame[0] = 0x10; // quadro-chave (P = 0)
    var col: Collect = .{};
    defer col.deinit();
    const n = packetizeVp8(&frame, 1100, 300, &col);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(usize, 4), vp8DescriptorLen(col.pkts.items[0]).?);
    var asm_: Assembler = .{ .codec = .vp8 };
    defer asm_.deinit(t.allocator);
    var got: ?Frame = null;
    for (0..n) |i| {
        if (asm_.push(t.allocator, @intCast(i), 50, col.markers.items[i], col.pkts.items[i])) |f| got = f;
    }
    try t.expectEqualSlices(u8, &frame, got.?.data);
    try t.expect(vp8Keyframe(got.?.data));
}

test "RTCP: PLI, FIR e Sender Report" {
    var p: [12]u8 = undefined;
    pli(&p, 11, 22);
    try t.expect(isRtcp(&p));
    try t.expect(wantsKeyframe(&p, 22));
    try t.expect(!wantsKeyframe(&p, 23));
    // Composto: um Receiver Report vazio e o PLI.
    var comp: [20]u8 = undefined;
    @memcpy(comp[0..8], &[_]u8{ 0x80, 201, 0, 1, 0, 0, 0, 11 });
    @memcpy(comp[8..20], &p);
    try t.expect(wantsKeyframe(&comp, 22));
    // FIR.
    var fir = [_]u8{ 0x84, 206, 0, 4, 0, 0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 22, 5, 0, 0, 0 };
    try t.expect(wantsKeyframe(&fir, 22));
    fir[15] = 23;
    try t.expect(!wantsKeyframe(&fir, 22));
    var sr: [28]u8 = undefined;
    senderReport(&sr, 5, 1000, 90_000, 10, 1000);
    try t.expect(isRtcp(&sr));
    try t.expectEqual(@as(u32, 2_208_988_801), std.mem.readInt(u32, sr[8..12], .big));
    // RTP de vídeo não é RTCP (101 com e sem marcador).
    var h: [header_len]u8 = undefined;
    writeHeader(&h, 101, true, 1, 2, 3);
    try t.expect(!isRtcp(&h));
    try t.expectEqual(@as(u8, 0x90), h[0]);
    try t.expectEqual(@as(u8, 0xE5), h[1]);
}

test "tamanho de saída: cabe na altura, lados pares, sem aumentar" {
    try t.expectEqual([2]u32{ 1280, 720 }, fitSize(1920, 1080, 720));
    try t.expectEqual([2]u32{ 1920, 1080 }, fitSize(1920, 1080, 1080));
    try t.expectEqual([2]u32{ 1366, 768 }, fitSize(1366, 768, 1080));
    try t.expectEqual([2]u32{ 1150, 720 }, fitSize(1680, 1051, 720));
    // Ultralarga: a largura para em 16:9 × 2.
    const u = fitSize(5120, 1440, 720);
    try t.expect(u[0] <= 2560 and u[1] <= 720 and u[0] % 2 == 0);
    try t.expectEqual([2]u32{ 0, 0 }, fitSize(0, 100, 720));
}
