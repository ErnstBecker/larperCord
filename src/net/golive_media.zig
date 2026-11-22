//! Transmissão de tela, a parte de mídia que não é rede:
//!
//!   - `share`: a thread que captura a tela (platform/tela.zig) e codifica
//!     (platform/video_codec.zig). Os quadros codificados esperam numa fila curta
//!     até a conexão da transmissão (net/voice.zig, tipo `stream_send`) levar; com a
//!     fila cheia a captura espera (descartar um quadro do meio estragaria os
//!     seguintes). Faz também a prévia pequena da própria tela, para o seu quadro na
//!     call.
//!   - `watch`: a thread que decodifica a transmissão que se está assistindo e deixa
//!     o quadro mais novo em RGBA para a interface (ui/golive_view.zig). Perdeu um
//!     pedaço, espera o próximo quadro-chave (e a conexão pede um).
//!   - a demonstração: sem Discord, a transmissão de alguém é a tela sintética
//!     passando pelo caminho inteiro (codificar, empacotar em RTP, remontar,
//!     decodificar). Testa tudo menos a rede.
//!
//! As threads só existem enquanto se transmite ou se assiste.
const std = @import("std");
const c = @import("c");
const golive = @import("../core/golive.zig");
const tela = @import("../platform/tela.zig");
const video_codec = @import("../platform/video_codec.zig");
const ffmpeg = @import("../platform/ffmpeg.zig");
const platform = @import("../platform/window.zig");

const alloc = std.heap.c_allocator;
const Id = u64;

fn nowMs() i64 {
    return @intCast(c.SDL_GetTicks());
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (@import("../platform/debug_log.zig").isOn() or c.SDL_getenv("LARPER_VOICE_DEBUG") != null) std.log.info("golive: " ++ fmt, args);
}

/// O tipo do evento que acorda a interface (o app passa no começo; 0 = não acorda).
pub var wake_type: u32 = 0;

/// No começo do app, antes de qualquer thread: os mutexes e o evento de acordar.
pub fn init(wake: u32) void {
    wake_type = wake;
    if (share.mutex == null) share.mutex = c.SDL_CreateMutex();
    if (watch.mutex == null) {
        watch.mutex = c.SDL_CreateMutex();
        watch.cond = c.SDL_CreateCondition();
    }
}
var wake_pending: std.atomic.Value(bool) = .init(false);

/// Acorda a interface, uma vez até ela desenhar de novo (`drawn`).
fn wakeUi() void {
    if (wake_type == 0) return;
    if (wake_pending.swap(true, .acq_rel)) return;
    platform.Window.wake(wake_type, .media);
}

/// A interface desenhou: o próximo quadro pode acordar de novo.
pub fn drawn() void {
    wake_pending.store(false, .release);
}

/// Bytes de uma imagem RGBA com a folga que o swscale pede.
fn rgbaLen(w: u32, h: u32) usize {
    return ffmpeg.rgbaSize(w, h);
}

/// Uma imagem RGBA para a interface (a mais nova), trocada sob o mutex.
pub const Picture = struct {
    px: std.ArrayList(u8) = .empty,
    w: u32 = 0,
    h: u32 = 0,
    seq: u64 = 0,
};

// ---------------------------------------------------------------------------
// Transmitir
// ---------------------------------------------------------------------------

pub const ShareState = enum(u8) { idle, opening, live, failed, ended };
pub const ShareFail = enum(u8) { none, missing, no_portal, cancelled, capture, no_encoder };

/// Um quadro codificado, esperando a conexão.
pub const EncFrame = struct {
    data: std.ArrayList(u8) = .empty,
    key: bool = false,
    w: u32 = 0,
    h: u32 = 0,
    /// Quando foi capturado (ms): o relógio do RTP sai daqui.
    ms: i64 = 0,
};

const queue_n = 3;

const Share = struct {
    mutex: ?*c.SDL_Mutex = null,
    thread: ?*c.SDL_Thread = null,
    state: std.atomic.Value(ShareState) = .init(.idle),
    fail: std.atomic.Value(ShareFail) = .init(.none),
    missing: [48]u8 = undefined,
    missing_len: usize = 0,
    stop: std.atomic.Value(bool) = .init(false),
    key_req: std.atomic.Value(bool) = .init(false),
    target: tela.Target = .{ .kind = .synthetic },
    quality: golive.Quality = .p720_30,
    codec: std.atomic.Value(golive.Codec) = .init(.h264),
    queue: [queue_n]EncFrame = @splat(.{}),
    head: usize = 0,
    len: usize = 0,
    /// O tamanho que sai do codificador (0 = ainda nenhum quadro).
    out_w: std.atomic.Value(u32) = .init(0),
    out_h: std.atomic.Value(u32) = .init(0),
    encoder: [24]u8 = @splat(0),
    preview: Picture = .{},
    /// Quantos quadros saíram (QA e o registro).
    encoded: std.atomic.Value(u32) = .init(0),
    /// Alguém está levando os quadros (a conexão de verdade). Sem ninguém (a
    /// demonstração), a fila é esvaziada aqui mesmo.
    consumer: std.atomic.Value(bool) = .init(false),
};

var share: Share = .{};

pub const ShareInfo = struct {
    state: ShareState,
    fail: ShareFail,
    missing: []const u8,
    w: u32,
    h: u32,
    quality: golive.Quality,
    encoder: []const u8,
    encoded: u32,
};

pub fn shareInfo(buf: *[48]u8) ShareInfo {
    lock();
    defer unlock();
    @memcpy(buf[0..share.missing_len], share.missing[0..share.missing_len]);
    return .{
        .state = share.state.load(.acquire),
        .fail = share.fail.load(.acquire),
        .missing = buf[0..share.missing_len],
        .w = share.out_w.load(.acquire),
        .h = share.out_h.load(.acquire),
        .quality = share.quality,
        .encoder = std.mem.sliceTo(&share.encoder, 0),
        .encoded = share.encoded.load(.acquire),
    };
}

fn lock() void {
    if (share.mutex == null) share.mutex = c.SDL_CreateMutex();
    c.SDL_LockMutex(share.mutex);
}

fn unlock() void {
    c.SDL_UnlockMutex(share.mutex);
}

/// Começa a capturar e codificar. No Wayland abre o diálogo do sistema (a thread
/// espera por ele). false = já está transmitindo ou não deu para criar a thread.
pub fn startShare(target: tela.Target, quality: golive.Quality) bool {
    stopShare();
    lock();
    share.target = target;
    share.quality = quality;
    share.fail.store(.none, .release);
    share.missing_len = 0;
    share.head = 0;
    share.len = 0;
    share.out_w.store(0, .release);
    share.out_h.store(0, .release);
    share.encoded.store(0, .release);
    share.encoder = @splat(0);
    share.preview.w = 0;
    share.preview.h = 0;
    share.stop.store(false, .release);
    share.state.store(.opening, .release);
    unlock();
    share.thread = c.SDL_CreateThread(shareMain, "golive-share", null) orelse {
        share.state.store(.failed, .release);
        share.fail.store(.capture, .release);
        return false;
    };
    return true;
}

pub fn stopShare() void {
    share.stop.store(true, .release);
    if (share.thread) |t| {
        c.SDL_WaitThread(t, null);
        share.thread = null;
    }
    lock();
    defer unlock();
    for (&share.queue) |*f| f.data.clearAndFree(alloc);
    share.len = 0;
    share.preview.px.clearAndFree(alloc);
    share.preview.w = 0;
    share.preview.h = 0;
    const st = share.state.load(.acquire);
    if (st == .opening or st == .live) share.state.store(.idle, .release);
}

/// Depois de mostrar o erro: volta ao começo.
pub fn clearShare() void {
    if (share.thread != null) return;
    share.state.store(.idle, .release);
    share.fail.store(.none, .release);
}

pub fn requestKeyframe() void {
    share.key_req.store(true, .release);
}

/// O codec que o Discord escolheu para a transmissão (op 4/op 14).
pub fn setShareCodec(cd: golive.Codec) void {
    if (share.codec.swap(cd, .acq_rel) != cd) requestKeyframe();
}

pub fn setConsumer(on: bool) void {
    share.consumer.store(on, .release);
}

/// A conexão leva o próximo quadro: troca o buffer dela pelo da fila (sem cópia).
pub fn takeFrame(out: *EncFrame) bool {
    lock();
    defer unlock();
    if (share.len == 0) return false;
    const slot = &share.queue[share.head];
    std.mem.swap(EncFrame, out, slot);
    slot.data.clearRetainingCapacity();
    share.head = (share.head + 1) % queue_n;
    share.len -= 1;
    return true;
}

/// A prévia da nossa tela (para o quadro da call), se mudou desde `seq`.
pub fn sharePreview(seq: u64, dst: *Picture) bool {
    lock();
    defer unlock();
    const p = &share.preview;
    if (p.seq == seq or p.w == 0) return false;
    dst.px.resize(alloc, p.px.items.len) catch return false;
    @memcpy(dst.px.items, p.px.items);
    dst.w = p.w;
    dst.h = p.h;
    dst.seq = p.seq;
    return true;
}

fn setFail(f: ShareFail, what: []const u8) void {
    lock();
    defer unlock();
    const n = @min(what.len, share.missing.len);
    @memcpy(share.missing[0..n], what[0..n]);
    share.missing_len = n;
    share.fail.store(f, .release);
    share.state.store(.failed, .release);
}

fn shareMain(_: ?*anyopaque) callconv(.c) c_int {
    _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_HIGH);
    defer wakeUi();
    const target = share.target;
    const q = share.quality;
    if (tela.missing(target.kind)) |what| {
        setFail(.missing, what);
        return 0;
    }
    if (ffmpeg.get() == null) {
        setFail(.missing, "FFmpeg");
        return 0;
    }
    if (!video_codec.canEncode(.h264)) {
        setFail(.no_encoder, "H.264");
        return 0;
    }
    var cap = tela.Capture.open(target, q.fps(), &share.stop) catch |e| {
        if (share.stop.load(.acquire)) return 0;
        switch (e) {
            error.Cancelled => setFail(.cancelled, ""),
            error.NoPortal => setFail(.no_portal, ""),
            error.Missing => setFail(.missing, tela.missing(target.kind) orelse "?"),
            error.Failed => setFail(.capture, ""),
        }
        return 0;
    };
    defer cap.close();
    if (share.stop.load(.acquire)) return 0;
    share.state.store(.live, .release);
    wakeUi();
    dbg("capturando ({t})", .{target.kind});

    var enc: ?video_codec.Encoder = null;
    defer if (enc) |*e| e.close();
    var enc_codec: golive.Codec = .h264;
    var last: std.ArrayList(u8) = .empty;
    defer last.deinit(alloc);
    var last_img: ?video_codec.Image = null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var scaler: video_codec.Scaler = .{};
    defer scaler.deinit();
    var preview_px: std.ArrayList(u8) = .empty;
    defer preview_px.deinit(alloc);
    const step_ms: i64 = @divTrunc(1000, @as(i64, q.fps()));
    var next_enc: i64 = 0;
    var last_enc: i64 = 0;
    var last_preview: i64 = 0;
    var last_key: i64 = 0;
    while (!share.stop.load(.acquire)) {
        if (cap.ended()) {
            share.state.store(.ended, .release);
            break;
        }
        const img_now = cap.next(@intCast(step_ms));
        const now = nowMs();
        if (img_now) |img| {
            // Guarda uma cópia: a tela parada é codificada de novo de vez em quando.
            const n = @as(usize, img.stride) * img.h;
            last.resize(alloc, n) catch continue;
            @memcpy(last.items, img.px[0..n]);
            last_img = .{ .px = last.items.ptr, .stride = img.stride, .w = img.w, .h = img.h, .fmt = img.fmt };
        }
        const img = last_img orelse continue;
        const want_key = share.key_req.load(.acquire) and now - last_key >= 700;
        // Nada novo: só um quadro por segundo (e o quadro-chave pedido).
        if (img_now == null and now - last_enc < 1000 and !want_key) continue;
        if (now < next_enc and !want_key) continue;
        // A fila cheia: a conexão está atrás. Sem ninguém levando (a demonstração), esvazia.
        if (!share.consumer.load(.acquire)) {
            lock();
            share.len = 0;
            unlock();
        }
        lock();
        const full = share.len == queue_n;
        unlock();
        if (full) continue;

        // O tamanho de saída: cabe na qualidade; a tela mudou de tamanho, reabre.
        const size = golive.fitSize(img.w, img.h, q.height());
        const cd = share.codec.load(.acquire);
        if (enc == null or enc.?.w != size[0] or enc.?.h != size[1] or enc_codec != cd) {
            if (enc) |*e| e.close();
            enc = null;
            enc = video_codec.Encoder.open(cd, size[0], size[1], q.fps(), q.kbps()) catch {
                setFail(.no_encoder, cd.name());
                break;
            };
            enc_codec = cd;
            share.out_w.store(size[0], .release);
            share.out_h.store(size[1], .release);
            lock();
            const nm = enc.?.name();
            share.encoder = @splat(0);
            @memcpy(share.encoder[0..@min(nm.len, share.encoder.len - 1)], nm[0..@min(nm.len, share.encoder.len - 1)]);
            unlock();
            dbg("codificador {s}, {d}x{d} a {d} qps, {d} kbit/s", .{ nm, size[0], size[1], q.fps(), q.kbps() });
            share.key_req.store(false, .release);
            last_key = now;
        } else if (want_key) {
            share.key_req.store(false, .release);
            enc.?.forceKeyframe();
            last_key = now;
        }
        const e = &enc.?;
        const got = e.encode(img, &out) catch {
            setFail(.no_encoder, cd.name());
            break;
        };
        last_enc = now;
        next_enc = @max(next_enc + step_ms, now - step_ms);
        if (got) |key| if (out.items.len > 0) {
            lock();
            const slot = &share.queue[(share.head + share.len) % queue_n];
            slot.data.clearRetainingCapacity();
            slot.data.appendSlice(alloc, out.items) catch {};
            slot.key = key;
            slot.w = e.w;
            slot.h = e.h;
            slot.ms = now;
            share.len += 1;
            unlock();
            _ = share.encoded.fetchAdd(1, .acq_rel);
        };
        // A prévia: 4 por segundo, pequena.
        if (now - last_preview >= 250) {
            last_preview = now;
            const ps = golive.fitSize(img.w, img.h, 180);
            preview_px.resize(alloc, rgbaLen(ps[0], ps[1])) catch continue;
            if (scaler.toRgba(img, preview_px.items, ps[0], ps[1])) {
                lock();
                std.mem.swap(std.ArrayList(u8), &share.preview.px, &preview_px);
                share.preview.w = ps[0];
                share.preview.h = ps[1];
                share.preview.seq +%= 1;
                unlock();
                wakeUi();
            }
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Assistir
// ---------------------------------------------------------------------------

pub const WatchState = enum(u8) { idle, connecting, waiting, playing, ended, failed };

const InFrame = struct { data: std.ArrayList(u8) = .empty, codec: golive.Codec = .h264, key: bool = false, loss: bool = false };

const Watch = struct {
    mutex: ?*c.SDL_Mutex = null,
    cond: ?*c.SDL_Condition = null,
    thread: ?*c.SDL_Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    user: std.atomic.Value(Id) = .init(0),
    state: std.atomic.Value(WatchState) = .init(.idle),
    queue: [4]InFrame = @splat(.{}),
    head: usize = 0,
    len: usize = 0,
    /// Perdemos o fio (pacote perdido, fila cheia): a conexão pede um quadro-chave.
    need_key: std.atomic.Value(bool) = .init(false),
    picture: Picture = .{},
    decoded: std.atomic.Value(u32) = .init(0),
    /// A demonstração: a thread que faz a transmissão de mentira.
    demo: ?*c.SDL_Thread = null,
};

var watch: Watch = .{};

fn wlock() void {
    if (watch.mutex == null) {
        watch.mutex = c.SDL_CreateMutex();
        watch.cond = c.SDL_CreateCondition();
    }
    c.SDL_LockMutex(watch.mutex);
}

fn wunlock() void {
    c.SDL_UnlockMutex(watch.mutex);
}

pub fn watchUser() Id {
    return watch.user.load(.acquire);
}

pub fn watchState() WatchState {
    return watch.state.load(.acquire);
}

pub fn watchDecoded() u32 {
    return watch.decoded.load(.acquire);
}

/// Começa a esperar a transmissão de `user` (a conexão ou a demonstração entregam).
pub fn watchBegin(user: Id) bool {
    watchEnd();
    wlock();
    watch.head = 0;
    watch.len = 0;
    watch.picture.w = 0;
    watch.picture.h = 0;
    wunlock();
    watch.decoded.store(0, .release);
    watch.stop.store(false, .release);
    watch.need_key.store(true, .release);
    watch.user.store(user, .release);
    watch.state.store(.connecting, .release);
    watch.thread = c.SDL_CreateThread(watchMain, "golive-watch", null) orelse {
        watch.state.store(.failed, .release);
        return false;
    };
    return true;
}

pub fn watchEnd() void {
    watch.stop.store(true, .release);
    if (watch.cond) |cd| c.SDL_BroadcastCondition(cd);
    if (watch.demo) |t| {
        c.SDL_WaitThread(t, null);
        watch.demo = null;
    }
    if (watch.thread) |t| {
        c.SDL_WaitThread(t, null);
        watch.thread = null;
    }
    wlock();
    for (&watch.queue) |*f| f.data.clearAndFree(alloc);
    watch.len = 0;
    watch.picture.px.clearAndFree(alloc);
    watch.picture.w = 0;
    watch.picture.h = 0;
    wunlock();
    watch.user.store(0, .release);
    watch.state.store(.idle, .release);
}

/// A transmissão acabou do outro lado (fica o último quadro até fechar).
pub fn watchEnded() void {
    if (watch.state.load(.acquire) != .idle) watch.state.store(.ended, .release);
    wakeUi();
}

/// A conexão de quem assiste quer um quadro-chave (o SSRC mudou, não decifrou).
pub fn requestWatchKeyframe() void {
    watch.need_key.store(true, .release);
}

/// A conexão pede um quadro-chave quando isto diz sim (e zera).
pub fn takeNeedKey() bool {
    return watch.need_key.swap(false, .acq_rel);
}

/// Um quadro remontado (e decifrado) da transmissão assistida.
pub fn pushEncoded(cd: golive.Codec, data: []const u8, loss: bool) void {
    if (watch.thread == null) return;
    const key = switch (cd) {
        .h264 => golive.h264Keyframe(data),
        .vp8 => golive.vp8Keyframe(data),
        else => false,
    };
    wlock();
    defer wunlock();
    if (watch.len == watch.queue.len) {
        // O decodificador está atrás: joga tudo fora e espera um quadro-chave.
        watch.len = 0;
        watch.need_key.store(true, .release);
    }
    const slot = &watch.queue[(watch.head + watch.len) % watch.queue.len];
    slot.data.clearRetainingCapacity();
    slot.data.appendSlice(alloc, data) catch return;
    slot.codec = cd;
    slot.key = key;
    slot.loss = loss;
    watch.len += 1;
    c.SDL_SignalCondition(watch.cond);
}

/// O quadro mais novo, se mudou desde `seq`.
pub fn watchPicture(seq: u64, dst: *Picture) bool {
    wlock();
    defer wunlock();
    const p = &watch.picture;
    if (p.seq == seq or p.w == 0) return false;
    std.mem.swap(std.ArrayList(u8), &dst.px, &p.px);
    dst.w = p.w;
    dst.h = p.h;
    dst.seq = p.seq;
    // O buffer velho volta para a thread reaproveitar; a imagem fica marcada como tomada.
    p.w = 0;
    return true;
}

/// O maior tamanho que a interface recebe (o resto o SDL estica).
const max_w: u32 = 1920;
const max_h: u32 = 1080;

fn watchMain(_: ?*anyopaque) callconv(.c) c_int {
    var dec: ?video_codec.Decoder = null;
    defer if (dec) |*d| d.close();
    var dec_codec: golive.Codec = .h264;
    var cur: InFrame = .{};
    defer cur.data.deinit(alloc);
    var px: std.ArrayList(u8) = .empty;
    defer px.deinit(alloc);
    var waiting_key = true;
    var seq: u64 = 0;
    while (!watch.stop.load(.acquire)) {
        wlock();
        while (watch.len == 0 and !watch.stop.load(.acquire)) _ = c.SDL_WaitConditionTimeout(watch.cond, watch.mutex, 200);
        if (watch.stop.load(.acquire)) {
            wunlock();
            break;
        }
        std.mem.swap(InFrame, &cur, &watch.queue[watch.head]);
        watch.head = (watch.head + 1) % watch.queue.len;
        watch.len -= 1;
        wunlock();

        if (cur.loss) waiting_key = true;
        if (waiting_key and !cur.key) {
            watch.need_key.store(true, .release);
            if (watch.state.load(.acquire) == .connecting) watch.state.store(.waiting, .release);
            continue;
        }
        if (dec == null or dec_codec != cur.codec) {
            if (dec) |*d| d.close();
            dec = video_codec.Decoder.open(cur.codec) catch {
                dec = null;
                watch.state.store(.failed, .release);
                wakeUi();
                continue;
            };
            dec_codec = cur.codec;
        }
        const d = &dec.?;
        switch (d.decode(cur.data.items)) {
            // Não decodificou: espera o próximo quadro-chave (e a conexão pede um).
            .failed => {
                waiting_key = true;
                watch.need_key.store(true, .release);
                continue;
            },
            // Aceitou e segurou a imagem (o primeiro quadro pode ficar preso): o fio
            // já está pego.
            .accepted => {
                waiting_key = false;
                continue;
            },
            .picture => waiting_key = false,
        }
        const sz = d.size();
        if (sz[0] == 0 or sz[1] == 0) continue;
        var ow = sz[0];
        var oh = sz[1];
        if (ow > max_w or oh > max_h) {
            const k = @min(@as(f64, @floatFromInt(max_w)) / @as(f64, @floatFromInt(ow)), @as(f64, @floatFromInt(max_h)) / @as(f64, @floatFromInt(oh)));
            ow = @max(2, @as(u32, @intFromFloat(@as(f64, @floatFromInt(ow)) * k)) & ~@as(u32, 1));
            oh = @max(2, @as(u32, @intFromFloat(@as(f64, @floatFromInt(oh)) * k)) & ~@as(u32, 1));
        }
        px.resize(alloc, rgbaLen(ow, oh)) catch continue;
        if (!d.toRgba(px.items, ow, oh)) continue;
        seq +%= 1;
        wlock();
        std.mem.swap(std.ArrayList(u8), &watch.picture.px, &px);
        watch.picture.w = ow;
        watch.picture.h = oh;
        watch.picture.seq = seq;
        wunlock();
        _ = watch.decoded.fetchAdd(1, .acq_rel);
        if (watch.state.load(.acquire) != .ended) watch.state.store(.playing, .release);
        wakeUi();
    }
    return 0;
}

// ---------------------------------------------------------------------------
// A demonstração
// ---------------------------------------------------------------------------

/// Sem Discord: a transmissão de `user` é a tela sintética passando pelo caminho
/// inteiro: codificar, empacotar em RTP (com perda de vez em quando, para o pedido
/// de quadro-chave aparecer), remontar e decodificar.
pub fn demoWatch(user: Id) bool {
    if (!watchBegin(user)) return false;
    watch.demo = c.SDL_CreateThread(demoMain, "golive-demo", null);
    return watch.demo != null;
}

const DemoSink = struct {
    asm_: *golive.Assembler,
    seq: u16 = 1,
    ts: u32 = 0,
    drop: bool = false,

    pub fn packet(s: *DemoSink, prefix: []const u8, body: []const u8, marker: bool) void {
        var buf: [golive.max_payload + 8]u8 = undefined;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..body.len], body);
        const seq = s.seq;
        s.seq +%= 1;
        if (s.drop) {
            s.drop = false;
            return;
        }
        if (s.asm_.push(alloc, seq, s.ts, marker, buf[0 .. prefix.len + body.len])) |f| pushEncoded(.h264, f.data, f.loss);
    }
};

fn demoMain(_: ?*anyopaque) callconv(.c) c_int {
    if (ffmpeg.get() == null or !video_codec.canEncode(.h264)) {
        watch.state.store(.failed, .release);
        wakeUi();
        return 0;
    }
    const fps: u32 = 30;
    var cap = tela.Capture.open(.{ .kind = .synthetic, .w = 1280, .h = 720 }, fps, &watch.stop) catch return 0;
    defer cap.close();
    var enc = video_codec.Encoder.open(.h264, 1280, 720, fps, 2500) catch {
        watch.state.store(.failed, .release);
        wakeUi();
        return 0;
    };
    defer enc.close();
    var asm_: golive.Assembler = .{};
    defer asm_.deinit(alloc);
    var sink: DemoSink = .{ .asm_ = &asm_ };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var n: u32 = 0;
    while (!watch.stop.load(.acquire)) {
        const img = cap.next(100) orelse continue;
        if (takeNeedKey() and n > 0) enc.forceKeyframe();
        const got = enc.encode(img, &out) catch break;
        if (got == null) continue;
        n += 1;
        sink.ts +%= golive.clock_hz / fps;
        // A cada ~10 s perde um pacote: o quadro some e o próximo espera o quadro-chave.
        sink.drop = n % 300 == 150;
        _ = golive.packetizeH264(out.items, golive.max_payload, &sink);
    }
    return 0;
}

/// Fim do app: para tudo (as threads saem sozinhas).
pub fn shutdown() void {
    stopShare();
    watchEnd();
}
