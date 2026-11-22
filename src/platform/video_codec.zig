//! Codificar a tela e decodificar a transmissão dos outros, com o FFmpeg do
//! sistema (platform/ffmpeg.zig): sem contêiner, quadro a quadro, em Annex B.
//!
//! Codificar: o primeiro codificador de H.264 que abrir, nesta ordem: libx264
//! (o das distribuições), os de placa de vídeo (NVENC, AMF, Quick Sync, Media
//! Foundation) e o OpenH264. Tudo em baixa latência: sem quadros B, o SPS e o PPS
//! repetidos em cada quadro-chave, um quadro-chave a cada 3 s. Pedir um
//! quadro-chave fora de hora (alguém começou a assistir, perdeu pacote) reabre o
//! codificador: funciona igual em todos, sem depender do layout do AVFrame.
//!
//! Decodificar: os decodificadores do próprio FFmpeg (h264, vp8…), sem threads
//! de quadro (cada thread a mais seria um quadro a mais de atraso).
const std = @import("std");
const ffmpeg = @import("ffmpeg.zig");
const golive = @import("../core/golive.zig");

const alloc = std.heap.c_allocator;
const Api = ffmpeg.Api;

/// Uma imagem crua da captura (4 bytes por pixel).
pub const Image = struct {
    px: [*]const u8,
    stride: u32,
    w: u32,
    h: u32,
    fmt: PixFmt,
};

/// Os formatos que as capturas entregam.
pub const PixFmt = enum {
    bgra,
    bgrx,
    rgba,
    rgbx,
    xrgb,
    xbgr,

    pub fn ffName(f: PixFmt) [*:0]const u8 {
        return switch (f) {
            .bgra => "bgra",
            .bgrx => "bgr0",
            .rgba => "rgba",
            .rgbx => "rgb0",
            .xrgb => "0rgb",
            .xbgr => "0bgr",
        };
    }
};

const Candidate = struct { name: [*:0]const u8, pix: [*:0]const u8, opts: []const [2][*:0]const u8 };

const h264_encoders = [_]Candidate{
    .{ .name = "libx264", .pix = "yuv420p", .opts = &.{
        .{ "preset", "veryfast" }, .{ "tune", "zerolatency" }, .{ "profile", "baseline" },
    } },
    .{ .name = "h264_nvenc", .pix = "yuv420p", .opts = &.{
        .{ "preset", "p2" }, .{ "tune", "ull" }, .{ "zerolatency", "1" }, .{ "rc", "cbr" }, .{ "profile", "baseline" },
    } },
    .{ .name = "h264_amf", .pix = "nv12", .opts = &.{
        .{ "usage", "ultralowlatency" }, .{ "rc", "cbr" }, .{ "profile", "constrained_baseline" },
    } },
    .{ .name = "h264_qsv", .pix = "nv12", .opts = &.{
        .{ "preset", "veryfast" }, .{ "profile", "baseline" },
    } },
    .{ .name = "h264_mf", .pix = "nv12", .opts = &.{
        .{ "rate_control", "cbr" }, .{ "scenario", "display_remoting" },
    } },
    .{ .name = "libopenh264", .pix = "yuv420p", .opts = &.{} },
};

const vp8_encoders = [_]Candidate{
    .{ .name = "libvpx", .pix = "yuv420p", .opts = &.{
        .{ "deadline", "realtime" }, .{ "cpu-used", "8" }, .{ "lag-in-frames", "0" }, .{ "error-resilient", "1" },
    } },
};

fn candidates(cd: golive.Codec) []const Candidate {
    return switch (cd) {
        .h264 => &h264_encoders,
        .vp8 => &vp8_encoders,
        else => &.{},
    };
}

/// Algum codificador deste codec existe no FFmpeg carregado? (Não abre nenhum.)
pub fn canEncode(cd: golive.Codec) bool {
    const a = ffmpeg.get() orelse return false;
    for (candidates(cd)) |cand| if (a.avcodec_find_encoder_by_name(cand.name) != null) return true;
    return false;
}

fn decoderName(cd: golive.Codec) [*:0]const u8 {
    return switch (cd) {
        .h264 => "h264",
        .vp8 => "vp8",
        .vp9 => "vp9",
        .h265 => "hevc",
        .av1 => "libdav1d",
    };
}

pub fn canDecode(cd: golive.Codec) bool {
    const a = ffmpeg.get() orelse return false;
    // Só os que remontamos (core/golive.zig): H.264 e VP8.
    if (cd != .h264 and cd != .vp8) return false;
    return a.avcodec_find_decoder_by_name(decoderName(cd)) != null;
}

const sws_fast_bilinear: c_int = 1;
const sws_bilinear: c_int = 2;

// --- Codificar ---------------------------------------------------------------

pub const Encoder = struct {
    api: *const Api,
    codec: golive.Codec,
    cand: usize = 0,
    ctx: ?*ffmpeg.CodecCtx = null,
    frame: ?*ffmpeg.Frame = null,
    pkt: ?*ffmpeg.Packet = null,
    sws: ?*ffmpeg.Sws = null,
    sws_key: [4]c_int = @splat(0),
    w: u32,
    h: u32,
    fps: u32,
    kbps: u32,
    pix: c_int = -1,
    pts: i64 = 0,
    /// O SPS e o PPS mais recentes: vão na frente do quadro-chave que vier sem eles.
    params: std.ArrayList(u8) = .empty,

    /// Abre o primeiro codificador que aceitar. `name` diz qual foi (para o registro).
    pub fn open(cd: golive.Codec, w: u32, h: u32, fps: u32, kbps: u32) !Encoder {
        const a = ffmpeg.get() orelse return error.NoFfmpeg;
        var e: Encoder = .{ .api = a, .codec = cd, .w = w, .h = h, .fps = fps, .kbps = kbps };
        errdefer e.close();
        e.frame = a.av_frame_alloc() orelse return error.NoMem;
        e.pkt = a.av_packet_alloc() orelse return error.NoMem;
        for (candidates(cd), 0..) |_, i| {
            if (e.openCandidate(i)) {
                e.cand = i;
                return e;
            }
        }
        return error.NoEncoder;
    }

    pub fn name(e: *const Encoder) []const u8 {
        return std.mem.span(candidates(e.codec)[e.cand].name);
    }

    fn openCandidate(e: *Encoder, i: usize) bool {
        const a = e.api;
        const cand = candidates(e.codec)[i];
        const codec = a.avcodec_find_encoder_by_name(cand.name) orelse return false;
        var ctx: ?*ffmpeg.CodecCtx = a.avcodec_alloc_context3(codec) orelse return false;
        var ok = true;
        var b: [64]u8 = undefined;
        const set = struct {
            fn s(api: *const Api, c: *ffmpeg.CodecCtx, k: [*:0]const u8, v: [*:0]const u8) bool {
                return api.av_opt_set(c, k, v, 1) >= 0; // AV_OPT_SEARCH_CHILDREN
            }
        }.s;
        ok = ok and set(a, ctx.?, "video_size", (std.fmt.bufPrintSentinel(&b, "{d}x{d}", .{ e.w, e.h }, 0) catch return false).ptr);
        ok = ok and set(a, ctx.?, "pixel_format", cand.pix);
        ok = ok and set(a, ctx.?, "time_base", (std.fmt.bufPrintSentinel(&b, "1/{d}", .{e.fps}, 0) catch return false).ptr);
        _ = set(a, ctx.?, "framerate", (std.fmt.bufPrintSentinel(&b, "{d}/1", .{e.fps}, 0) catch return false).ptr);
        _ = a.av_opt_set_int(ctx.?, "b", @as(i64, e.kbps) * 1000, 0);
        _ = a.av_opt_set_int(ctx.?, "maxrate", @divTrunc(@as(i64, e.kbps) * 1000 * 5, 4), 0);
        // Meio segundo de folga: a tela parada gasta quase nada, a que muda pega o que precisa.
        _ = a.av_opt_set_int(ctx.?, "bufsize", @as(i64, e.kbps) * 500, 0);
        _ = a.av_opt_set_int(ctx.?, "g", @as(i64, e.fps) * 3, 0);
        _ = a.av_opt_set_int(ctx.?, "bf", 0, 0);
        _ = a.av_opt_set_int(ctx.?, "threads", @min(4, @max(1, std.Thread.getCpuCount() catch 2) / 2), 0);
        for (cand.opts) |kv| _ = set(a, ctx.?, kv[0], kv[1]);
        if (!ok or a.avcodec_open2(ctx.?, codec, null) < 0) {
            a.avcodec_free_context(&ctx);
            return false;
        }
        const pix = a.av_get_pix_fmt(cand.pix);
        if (pix < 0) {
            a.avcodec_free_context(&ctx);
            return false;
        }
        a.av_frame_unref(e.frame.?);
        ffmpeg.setFrame(e.frame.?, @intCast(e.w), @intCast(e.h), pix);
        if (a.av_frame_get_buffer(e.frame.?, 0) < 0) {
            a.avcodec_free_context(&ctx);
            return false;
        }
        if (e.ctx != null) a.avcodec_free_context(&e.ctx);
        e.ctx = ctx;
        e.pix = pix;
        e.pts = 0;
        return true;
    }

    /// O próximo quadro sai como quadro-chave: reabre o mesmo codificador.
    pub fn forceKeyframe(e: *Encoder) void {
        if (!e.openCandidate(e.cand)) {
            // Não reabriu: tenta os outros; sem nenhum, o próximo encode falha e a
            // transmissão para com o aviso.
            for (candidates(e.codec), 0..) |_, i| if (i != e.cand and e.openCandidate(i)) {
                e.cand = i;
                return;
            };
            if (e.ctx != null) e.api.avcodec_free_context(&e.ctx);
        }
    }

    pub fn close(e: *Encoder) void {
        const a = e.api;
        if (e.ctx != null) a.avcodec_free_context(&e.ctx);
        if (e.frame != null) a.av_frame_free(&e.frame);
        if (e.pkt != null) a.av_packet_free(&e.pkt);
        if (e.sws) |s| a.sws_freeContext(s);
        e.sws = null;
        e.params.deinit(alloc);
    }

    /// Codifica uma imagem (redimensionada para o tamanho do codificador). O que sair
    /// vai para `out` (apagado antes); `key` diz se é quadro-chave. null = nada saiu
    /// ainda (o codificador segura um quadro) ou falhou.
    pub fn encode(e: *Encoder, img: Image, out: *std.ArrayList(u8)) error{ Encode, NoMem }!?bool {
        const a = e.api;
        const ctx = e.ctx orelse return error.Encode;
        const f = e.frame.?;
        if (a.av_frame_make_writable(f) < 0) return error.Encode;
        const src_fmt = a.av_get_pix_fmt(img.fmt.ffName());
        const key = [4]c_int{ @intCast(img.w), @intCast(img.h), src_fmt, e.pix };
        if (e.sws == null or !std.mem.eql(c_int, &key, &e.sws_key)) {
            if (e.sws) |s| a.sws_freeContext(s);
            // Diminuir texto de tela: o bilinear de verdade (o "rápido" serrilha as letras).
            e.sws = a.sws_getContext(key[0], key[1], key[2], @intCast(e.w), @intCast(e.h), e.pix, if (img.w == e.w and img.h == e.h) sws_fast_bilinear else sws_bilinear, null, null, null);
            e.sws_key = key;
        }
        const s = e.sws orelse return error.Encode;
        const planes: [4]?[*]const u8 = .{ img.px, null, null, null };
        const strides: [4]c_int = .{ @intCast(img.stride), 0, 0, 0 };
        const dst: *const [8]?[*]u8 = ffmpeg.frameData(f);
        if (a.sws_scale(s, &planes, &strides, 0, @intCast(img.h), dst, ffmpeg.frameLinesize(f)) <= 0) return error.Encode;
        ffmpeg.setFramePts(f, e.pts);
        e.pts += 1;
        if (a.avcodec_send_frame(ctx, f) < 0) return error.Encode;
        out.clearRetainingCapacity();
        var got: ?bool = null;
        const p = e.pkt.?;
        while (true) {
            const rc = a.avcodec_receive_packet(ctx, p);
            if (rc == ffmpeg.err_again or rc == ffmpeg.err_eof) break;
            if (rc < 0) return error.Encode;
            defer a.av_packet_unref(p);
            const data = ffmpeg.packetData(p);
            var k = ffmpeg.packetKey(p);
            if (e.codec == .h264) {
                k = k or golive.h264Keyframe(data);
                if (k) try e.withParams(data, out) else out.appendSlice(alloc, data) catch return error.NoMem;
            } else out.appendSlice(alloc, data) catch return error.NoMem;
            got = (got orelse false) or k;
        }
        return got;
    }

    /// Quadro-chave do H.264: guarda o SPS/PPS que vier; se não veio, põe o último na frente.
    fn withParams(e: *Encoder, data: []const u8, out: *std.ArrayList(u8)) error{NoMem}!void {
        var has_sps = false;
        var it = golive.Nals.init(data);
        var fresh: std.ArrayList(u8) = .empty;
        defer fresh.deinit(alloc);
        while (it.nextUnit()) |nal| {
            if (nal.len == 0) continue;
            const typ = nal[0] & 0x1f;
            if (typ == 7 or typ == 8) {
                if (typ == 7) has_sps = true;
                fresh.appendSlice(alloc, &.{ 0, 0, 0, 1 }) catch return error.NoMem;
                fresh.appendSlice(alloc, nal) catch return error.NoMem;
            }
        }
        if (has_sps) {
            e.params.clearRetainingCapacity();
            e.params.appendSlice(alloc, fresh.items) catch return error.NoMem;
        } else out.appendSlice(alloc, e.params.items) catch return error.NoMem;
        out.appendSlice(alloc, data) catch return error.NoMem;
    }
};

// --- Decodificar -------------------------------------------------------------

pub const Decoder = struct {
    api: *const Api,
    ctx: ?*ffmpeg.CodecCtx = null,
    frame: ?*ffmpeg.Frame = null,
    spare: ?*ffmpeg.Frame = null,
    pkt: ?*ffmpeg.Packet = null,
    sws: ?*ffmpeg.Sws = null,
    sws_key: [5]c_int = @splat(0),

    pub fn open(cd: golive.Codec) !Decoder {
        const a = ffmpeg.get() orelse return error.NoFfmpeg;
        var d: Decoder = .{ .api = a };
        errdefer d.close();
        const codec = a.avcodec_find_decoder_by_name(decoderName(cd)) orelse return error.NoDecoder;
        d.ctx = a.avcodec_alloc_context3(codec) orelse return error.NoMem;
        _ = a.av_opt_set(d.ctx.?, "thread_type", "slice", 0);
        _ = a.av_opt_set_int(d.ctx.?, "threads", 2, 0);
        if (a.avcodec_open2(d.ctx.?, codec, null) < 0) return error.Codec;
        d.frame = a.av_frame_alloc() orelse return error.NoMem;
        d.spare = a.av_frame_alloc() orelse return error.NoMem;
        d.pkt = a.av_packet_alloc() orelse return error.NoMem;
        return d;
    }

    pub fn close(d: *Decoder) void {
        const a = d.api;
        if (d.ctx != null) a.avcodec_free_context(&d.ctx);
        if (d.frame != null) a.av_frame_free(&d.frame);
        if (d.spare != null) a.av_frame_free(&d.spare);
        if (d.pkt != null) a.av_packet_free(&d.pkt);
        if (d.sws) |s| a.sws_freeContext(s);
        d.sws = null;
    }

    pub const Result = enum { failed, accepted, picture };

    /// Um quadro inteiro (Annex B ou VP8). `picture`: saiu uma imagem (em `frame`);
    /// `accepted`: o decodificador aceitou e ainda não soltou imagem (ele pode
    /// segurar a primeira).
    pub fn decode(d: *Decoder, data: []const u8) Result {
        const a = d.api;
        const p = d.pkt.?;
        if (data.len == 0 or data.len > 32 << 20) return .failed;
        if (a.av_new_packet(p, @intCast(data.len)) < 0) return .failed;
        @memcpy(ffmpeg.packetData(p)[0..data.len], data);
        const rc = a.avcodec_send_packet(d.ctx.?, p);
        a.av_packet_unref(p);
        if (rc < 0 and rc != ffmpeg.err_again) return .failed;
        // O receive apaga o quadro antes de tentar: recebe no reserva e troca quando
        // vem imagem (a última que sair fica em `frame`).
        var got = false;
        while (a.avcodec_receive_frame(d.ctx.?, d.spare.?) == 0) {
            std.mem.swap(?*ffmpeg.Frame, &d.frame, &d.spare);
            got = true;
        }
        return if (got) .picture else .accepted;
    }

    pub fn size(d: *const Decoder) [2]u32 {
        const f = d.frame.?;
        return .{ @intCast(@max(0, ffmpeg.frameWidth(f))), @intCast(@max(0, ffmpeg.frameHeight(f))) };
    }

    /// O último quadro em RGBA, `dw`×`dh` (precisa de `ffmpeg.rgbaSize(dw, dh)` bytes).
    pub fn toRgba(d: *Decoder, dst: []u8, dw: u32, dh: u32) bool {
        const a = d.api;
        const f = d.frame.?;
        if (dst.len < ffmpeg.rgbaSize(dw, dh)) return false;
        const key = [5]c_int{ ffmpeg.frameWidth(f), ffmpeg.frameHeight(f), ffmpeg.frameFormat(f), @intCast(dw), @intCast(dh) };
        if (key[0] <= 0 or key[1] <= 0 or key[0] > 8192 or key[1] > 8192) return false;
        if (d.sws == null or !std.mem.eql(c_int, &key, &d.sws_key)) {
            if (d.sws) |s| a.sws_freeContext(s);
            d.sws = a.sws_getContext(key[0], key[1], key[2], key[3], key[4], a.av_get_pix_fmt("rgba"), sws_bilinear, null, null, null);
            d.sws_key = key;
        }
        const s = d.sws orelse return false;
        const planes: [4]?[*]u8 = .{ dst.ptr, null, null, null };
        const strides: [4]c_int = .{ @intCast(dw * 4), 0, 0, 0 };
        const src: *const [8]?[*]const u8 = @ptrCast(ffmpeg.frameData(f));
        return a.sws_scale(s, src, ffmpeg.frameLinesize(f), 0, key[1], &planes, &strides) > 0;
    }
};

/// Uma imagem qualquer em RGBA, reduzida (a prévia da nossa própria tela).
pub const Scaler = struct {
    sws: ?*ffmpeg.Sws = null,
    key: [5]c_int = @splat(0),

    pub fn deinit(s: *Scaler) void {
        if (s.sws) |x| if (ffmpeg.get()) |a| a.sws_freeContext(x);
        s.sws = null;
    }

    pub fn toRgba(s: *Scaler, img: Image, dst: []u8, dw: u32, dh: u32) bool {
        const a = ffmpeg.get() orelse return false;
        if (dst.len < ffmpeg.rgbaSize(dw, dh)) return false;
        const key = [5]c_int{ @intCast(img.w), @intCast(img.h), a.av_get_pix_fmt(img.fmt.ffName()), @intCast(dw), @intCast(dh) };
        if (s.sws == null or !std.mem.eql(c_int, &key, &s.key)) {
            if (s.sws) |x| a.sws_freeContext(x);
            s.sws = a.sws_getContext(key[0], key[1], key[2], key[3], key[4], a.av_get_pix_fmt("rgba"), sws_bilinear, null, null, null);
            s.key = key;
        }
        const sw = s.sws orelse return false;
        const planes: [4]?[*]const u8 = .{ img.px, null, null, null };
        const strides: [4]c_int = .{ @intCast(img.stride), 0, 0, 0 };
        const dplanes: [4]?[*]u8 = .{ dst.ptr, null, null, null };
        const dstrides: [4]c_int = .{ @intCast(dw * 4), 0, 0, 0 };
        return a.sws_scale(sw, &planes, &strides, 0, @intCast(img.h), &dplanes, &dstrides) > 0;
    }
};
