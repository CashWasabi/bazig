//! Sound from oscillators, sweeps and noise, with no audio files.
//! A sound is a short mono clip in a slice of floats in -1..1.
//! Start from silence and add notes and bursts of noise to it.
//! `writeWav` turns a clip into the bytes of a 16-bit PCM WAV file.
//! `audio.Engine.registerData` takes those bytes.
//!
//!     var clip: [22_050 / 4]f32 = @splat(0); // A quarter second.
//!     synth.note(&clip, 22_050, .{ .length_s = 0.08, .from_hz = 988, .wave = .square, .amp = 0.25, .decay_s = 0.08 });
//!     synth.burst(&clip, 22_050, .{ .length_s = 0.03, .amp = 0.1, .decay_s = 0.01, .seed = 11 });
//!
//! Everything here is deterministic and allocates nothing.
//! The same call gives the same samples, bit for bit, in Debug and in release builds.
//! So a sound can be tested like any function, for its pitch, for clipping and for clicks.
//! `zig build bench` measures what a sound costs to render.
const std = @import("std");
const assert = std.debug.assert;

pub const Wave = enum(u8) { sine, square, saw, triangle };

/// The highest sample rate a clip may have.
/// It keeps the WAV header's byte rate within a `u32`.
pub const max_sample_rate: u32 = 384_000;

/// The value of `wave` at `phase`, in -1..1.
/// `phase` is in cycles.
/// Only its fraction counts.
pub fn waveAt(wave: Wave, phase: f32) f32 {
    const p = phase - @floor(phase); // 0..1
    return switch (wave) {
        .sine => @sin(p * std.math.tau),
        .square => if (p < 0.5) 1.0 else -1.0,
        .saw => p * 2.0 - 1.0,
        .triangle => 1.0 - 4.0 * @abs(p - 0.5),
    };
}

/// A tiny deterministic noise source.
/// It is an xorshift, so a sound is the same every time.
pub const Noise = struct {
    state: u32 = default_state,

    const default_state: u32 = 0x9E3779B9;

    /// Noise picked by `seed`.
    /// Seed 0 gets the default state.
    /// A state of zero would stay zero for ever, and every sample would be -1.
    pub fn init(seed: u32) Noise {
        return .{ .state = if (seed == 0) default_state else seed };
    }

    /// The next sample, -1..1.
    pub fn next(self: *Noise) f32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return @as(f32, @floatFromInt(x >> 8)) / @as(f32, 8388608.0) - 1.0;
    }
};

/// How long a note takes to fade in.
/// The fades stop a sound starting or ending with a click.
pub const note_fade_in_s: f32 = 0.002;
/// How long a note or a burst takes to fade out.
pub const fade_out_s: f32 = 0.005;
/// How long a burst takes to fade in.
/// It is faster than a note, because its attack is part of its sound.
pub const burst_fade_in_s: f32 = 0.001;

pub const Note = struct {
    /// When it starts, in seconds from the start of the clip.
    start_s: f32 = 0,
    length_s: f32,
    /// Its pitch at the start.
    from_hz: f32,
    /// Its pitch at the end.
    /// It glides from `from_hz` to this.
    /// Null keeps it at `from_hz`.
    to_hz: ?f32 = null,
    wave: Wave = .sine,
    /// Its loudness at the start, 0..1.
    amp: f32 = 1.0,
    /// How fast it dies away.
    /// After this many seconds it is down to 37%, which is 1/e.
    /// Much longer than `length_s` holds its level.
    /// Much shorter is a pluck.
    decay_s: f32,
};

/// Adds a note to `out`, a clip at `sample_rate` samples a second.
/// What falls past the end of `out` is dropped.
pub fn note(out: []f32, sample_rate: u32, n: Note) void {
    assert(sample_rate > 0 and sample_rate <= max_sample_rate);
    assert(n.start_s >= 0 and n.length_s >= 0 and n.decay_s > 0);
    const rate: f32 = @floatFromInt(sample_rate);
    const first_idx = frameIndex(n.start_s, rate, out.len);
    const frame_count: usize = @intFromFloat(n.length_s * rate);
    const to_hz = n.to_hz orelse n.from_hz;
    var phase: f32 = 0;
    for (out[first_idx..][0..@min(frame_count, out.len - first_idx)], 0..) |*sample, i| {
        const t = @as(f32, @floatFromInt(i)) / rate;
        const glide = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(frame_count, 1)));
        const freq = n.from_hz + (to_hz - n.from_hz) * glide;
        phase += freq / rate;
        const fade_in = @min(t / note_fade_in_s, 1.0);
        const fade_out = @min((n.length_s - t) / fade_out_s, 1.0);
        sample.* += waveAt(n.wave, phase) * n.amp * @exp(-t / n.decay_s) * fade_in * fade_out;
    }
}

/// The index of the frame `start_s` seconds in, at most `frame_count`.
/// The clamp happens in floats, so a start far past the end cannot overflow.
fn frameIndex(start_s: f32, rate: f32, frame_count: usize) usize {
    return @intFromFloat(@min(start_s * rate, @as(f32, @floatFromInt(frame_count))));
}

pub const Burst = struct {
    start_s: f32 = 0,
    length_s: f32,
    amp: f32 = 1.0,
    /// How fast it dies away, as `Note.decay_s`.
    decay_s: f32,
    /// How dull it is, in 0..1, below 1.
    /// 0 is bright hiss and near 1 is a low rumble.
    /// It is a one-pole low-pass.
    smooth: f32 = 0,
    /// Which noise.
    /// The same seed gives the same burst.
    seed: u32 = 1,
};

/// Adds a burst of noise to `out`, a clip at `sample_rate` samples a second.
/// What falls past the end of `out` is dropped.
pub fn burst(out: []f32, sample_rate: u32, b: Burst) void {
    assert(sample_rate > 0 and sample_rate <= max_sample_rate);
    assert(b.start_s >= 0 and b.length_s >= 0 and b.decay_s > 0);
    assert(b.smooth >= 0 and b.smooth < 1);
    const rate: f32 = @floatFromInt(sample_rate);
    const first_idx = frameIndex(b.start_s, rate, out.len);
    const frame_count: usize = @intFromFloat(b.length_s * rate);
    var noise: Noise = .init(b.seed);
    var low: f32 = 0;
    for (out[first_idx..][0..@min(frame_count, out.len - first_idx)], 0..) |*sample, i| {
        const t = @as(f32, @floatFromInt(i)) / rate;
        low = low * b.smooth + noise.next() * (1.0 - b.smooth);
        const fade_out = @min((b.length_s - t) / fade_out_s, 1.0);
        sample.* += low * b.amp * @exp(-t / b.decay_s) * @min(t / burst_fade_in_s, 1.0) * fade_out;
    }
}

/// The size of a WAV file's header as `writeWav` writes it.
pub const wav_header_bytes = 44;

/// The most samples one WAV file holds.
/// The file's size must fit the header's `u32`.
pub const max_wav_frame_count: usize = (std.math.maxInt(u32) - wav_header_bytes) / 2;

/// How many bytes `writeWav` writes for `frame_count` samples.
pub fn wavSize(frame_count: usize) usize {
    return wav_header_bytes + frame_count * 2;
}

/// Writes `samples` as a mono 16-bit PCM WAV file into `buffer`, and returns the file's bytes.
/// `buffer` holds at least `wavSize(samples.len)` bytes.
/// Samples are clipped to -1..1.
pub fn writeWav(samples: []const f32, sample_rate: u32, buffer: []u8) []u8 {
    assert(sample_rate > 0 and sample_rate <= max_sample_rate);
    assert(samples.len <= max_wav_frame_count);
    assert(buffer.len >= wavSize(samples.len));
    const data_len: u32 = @intCast(samples.len * 2);
    @memcpy(buffer[0..4], "RIFF");
    std.mem.writeInt(u32, buffer[4..8], 36 + data_len, .little);
    @memcpy(buffer[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, buffer[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, buffer[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, buffer[22..24], 1, .little); // mono
    std.mem.writeInt(u32, buffer[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buffer[28..32], sample_rate * 2, .little); // byte rate
    std.mem.writeInt(u16, buffer[32..34], 2, .little); // block align
    std.mem.writeInt(u16, buffer[34..36], 16, .little); // bits per sample
    @memcpy(buffer[36..40], "data");
    std.mem.writeInt(u32, buffer[40..44], data_len, .little);
    for (samples, 0..) |sample, i| {
        const clipped = std.math.clamp(sample, -1.0, 1.0);
        std.mem.writeInt(i16, buffer[wav_header_bytes + i * 2 ..][0..2], @intFromFloat(clipped * 32767.0), .little);
    }
    return buffer[0..wavSize(samples.len)];
}

const testing = std.testing;

fn crossings(samples: []const f32) usize {
    var count: usize = 0;
    for (samples[0 .. samples.len - 1], samples[1..]) |x, y| count += @intFromBool((x < 0) != (y < 0));
    return count;
}

fn peak(samples: []const f32) f32 {
    var highest: f32 = 0;
    for (samples) |s| highest = @max(highest, @abs(s));
    return highest;
}

test "the waves span -1..1 and a sine starts at 0" {
    try testing.expectApproxEqAbs(@as(f32, 0), waveAt(.sine, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), waveAt(.sine, 0.25), 1e-6);
    try testing.expectEqual(@as(f32, 1), waveAt(.square, 0.1));
    try testing.expectEqual(@as(f32, -1), waveAt(.square, 1.6)); // only the fraction counts
    try testing.expectEqual(@as(f32, -1), waveAt(.saw, 0));
    try testing.expectEqual(@as(f32, 1), waveAt(.triangle, 0.5));
    for (std.enums.values(Wave)) |wave| {
        for (0..400) |k| {
            const sample = waveAt(wave, @as(f32, @floatFromInt(k)) / 100.0 - 2.0);
            try testing.expect(sample >= -1 and sample <= 1);
        }
    }
}

test "noise is deterministic, stays in -1..1, and differs by seed" {
    var a: Noise = .init(7);
    var b: Noise = .init(7);
    var c: Noise = .init(8);
    var differs = false;
    for (0..1000) |_| {
        const x = a.next();
        try testing.expectEqual(x, b.next());
        try testing.expect(x >= -1 and x < 1);
        if (x != c.next()) differs = true;
    }
    try testing.expect(differs);
}

test "a noise seed of zero is still noise, not a stuck level" {
    var noise: Noise = .init(0);
    var lowest: f32 = 1;
    var highest: f32 = -1;
    for (0..200) |_| {
        const x = noise.next();
        lowest = @min(lowest, x);
        highest = @max(highest, x);
    }
    try testing.expect(lowest < -0.5 and highest > 0.5); // it goes both ways
    var out: [800]f32 = @splat(0);
    burst(&out, 8000, .{ .length_s = 0.1, .decay_s = 1, .seed = 0 });
    try testing.expect(crossings(&out) > 100);
}

test "a note has the pitch asked for, starts where asked, and is dropped past the end" {
    const rate = 8000;
    var out: [4000]f32 = @splat(0);
    note(&out, rate, .{ .start_s = 0.1, .length_s = 0.4, .from_hz = 200, .wave = .square, .amp = 0.5, .decay_s = 100 });
    for (out[0..800]) |s| try testing.expectEqual(@as(f32, 0), s);
    try testing.expectApproxEqAbs(@as(f32, 2 * 200 * 3000.0 / rate), @as(f32, @floatFromInt(crossings(out[900..3901]))), 3);
    var short: [10]f32 = @splat(0);
    note(&short, rate, .{ .length_s = 1, .from_hz = 440, .decay_s = 1 }); // Longer than the buffer: no overrun.
    var late: [10]f32 = @splat(0);
    note(&late, rate, .{ .start_s = 1e30, .length_s = 1, .from_hz = 440, .decay_s = 1 }); // Starts past the end.
    burst(&late, rate, .{ .start_s = 1, .length_s = 1, .decay_s = 1 });
    for (late) |s| try testing.expectEqual(@as(f32, 0), s);
}

test "a note glides from one pitch to the other" {
    const rate = 8000;
    var out: [8000]f32 = @splat(0);
    note(&out, rate, .{ .length_s = 1, .from_hz = 100, .to_hz = 400, .decay_s = 100 });
    const early = crossings(out[0..2000]);
    const late = crossings(out[6000..8000]);
    try testing.expect(late > 2 * early); // about 137 Hz against about 363 Hz
    var falling: [8000]f32 = @splat(0);
    note(&falling, rate, .{ .length_s = 1, .from_hz = 400, .to_hz = 100, .decay_s = 100 });
    try testing.expect(crossings(falling[0..2000]) > 2 * crossings(falling[6000..8000]));
}

test "a note starts and ends in silence, never passes its loudness, and dies away" {
    const rate = 8000;
    var out: [4000]f32 = @splat(0);
    note(&out, rate, .{ .length_s = 0.5, .from_hz = 220, .wave = .square, .amp = 0.4, .decay_s = 0.1 });
    try testing.expectEqual(@as(f32, 0), out[0]); // it fades in from nothing
    try testing.expect(peak(&out) <= 0.4);
    try testing.expect(peak(out[100..500]) > 4 * peak(out[2500..2900])); // a quarter second later: much quieter

    // a note that holds its level to the end: only the fades bring its ends to nothing
    var held: [4000]f32 = @splat(0);
    note(&held, rate, .{ .length_s = 0.5, .from_hz = 220, .wave = .square, .amp = 0.4, .decay_s = 1000 });
    try testing.expectApproxEqAbs(@as(f32, 0.4), peak(held[1000..3000]), 0.01); // full level in the middle
    try testing.expectEqual(@as(f32, 0), held[0]);
    try testing.expect(@abs(held[1]) < 0.05 and @abs(held[3999]) < 0.02); // no step at either end
    try testing.expect(@abs(held[3990]) < 0.12 and @abs(held[3990]) > @abs(held[3999])); // it ramps down
}

test "notes and bursts add to what is there" {
    const rate = 8000;
    var one: [800]f32 = @splat(0);
    var both: [800]f32 = @splat(0);
    const a: Note = .{ .length_s = 0.1, .from_hz = 300, .amp = 0.3, .decay_s = 1 };
    const b: Burst = .{ .length_s = 0.1, .amp = 0.2, .decay_s = 1, .seed = 3 };
    note(&one, rate, a);
    note(&both, rate, a);
    burst(&both, rate, b);
    var only_burst: [800]f32 = @splat(0);
    burst(&only_burst, rate, b);
    for (one, both, only_burst) |x, sum, y| try testing.expectApproxEqAbs(x + y, sum, 1e-6);
}

test "a burst is the same for the same seed, different for another, and dies away" {
    const rate = 8000;
    var a: [2400]f32 = @splat(0);
    var b: [2400]f32 = @splat(0);
    var c: [2400]f32 = @splat(0);
    burst(&a, rate, .{ .length_s = 0.3, .amp = 0.8, .decay_s = 0.05, .seed = 5 });
    burst(&b, rate, .{ .length_s = 0.3, .amp = 0.8, .decay_s = 0.05, .seed = 5 });
    burst(&c, rate, .{ .length_s = 0.3, .amp = 0.8, .decay_s = 0.05, .seed = 6 });
    try testing.expectEqualSlices(f32, &a, &b);
    try testing.expect(!std.mem.eql(f32, &a, &c));
    try testing.expectEqual(@as(f32, 0), a[0]);
    try testing.expect(peak(&a) <= 0.8);
    try testing.expect(peak(a[0..400]) > 5 * peak(a[1600..2000]));
}

test "a smoother burst is duller: it crosses zero less often" {
    const rate = 8000;
    var bright: [4000]f32 = @splat(0);
    var dull: [4000]f32 = @splat(0);
    burst(&bright, rate, .{ .length_s = 0.5, .decay_s = 10, .smooth = 0, .seed = 9 });
    burst(&dull, rate, .{ .length_s = 0.5, .decay_s = 10, .smooth = 0.95, .seed = 9 });
    try testing.expect(crossings(&bright) > 3 * crossings(&dull));
}

test "the WAV is a well-formed mono 16-bit file holding the samples, clipped" {
    const samples = [_]f32{ 0, 0.5, -0.5, 2, -2 };
    var buffer: [wavSize(samples.len)]u8 = undefined;
    const bytes = writeWav(&samples, 22_050, &buffer);
    try testing.expectEqual(@as(usize, 54), bytes.len);
    try testing.expectEqualStrings("RIFF", bytes[0..4]);
    try testing.expectEqual(@as(u32, 46), std.mem.readInt(u32, bytes[4..8], .little)); // the file's size less 8
    try testing.expectEqualStrings("WAVE", bytes[8..12]);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[22..24], .little)); // mono
    try testing.expectEqual(@as(u32, 22_050), std.mem.readInt(u32, bytes[24..28], .little));
    try testing.expectEqual(@as(u32, 44_100), std.mem.readInt(u32, bytes[28..32], .little)); // bytes a second
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[34..36], .little));
    try testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, bytes[40..44], .little));
    try testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, bytes[44..46], .little));
    try testing.expectEqual(@as(i16, 16383), std.mem.readInt(i16, bytes[46..48], .little));
    try testing.expectEqual(@as(i16, -16383), std.mem.readInt(i16, bytes[48..50], .little));
    try testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, bytes[50..52], .little)); // clipped
    try testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, bytes[52..54], .little));
    try testing.expectEqual(@as(usize, wav_header_bytes), wavSize(0));
}
