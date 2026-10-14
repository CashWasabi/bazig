//! What a sound costs to render, measured.
//! Run it with `zig build bench`, which always builds ReleaseFast.
//!
//! It renders the three sounds of `synth_sounds.zig` over and over, and writes each as a WAV.
//! It prints the time for one set and the seconds of sound made per millisecond.
const std = @import("std");
const synth = @import("bazig").synth;

const rate: u32 = 22_050;
const round_count = 1000;

/// A coin, a laser and an explosion, as in `synth_sounds.zig`: 1.2 seconds of sound.
const coin_frame_count = 7056;
const laser_frame_count = 3970;
const boom_frame_count = 15435;
const sound_frame_count = coin_frame_count + laser_frame_count + boom_frame_count;

fn renderAll(clip: *[sound_frame_count]f32) void {
    @memset(clip, 0);
    const coin = clip[0..coin_frame_count];
    const laser = clip[coin_frame_count..][0..laser_frame_count];
    const boom = clip[coin_frame_count + laser_frame_count ..];
    synth.note(coin, rate, .{ .length_s = 0.07, .from_hz = 988, .wave = .square, .amp = 0.25, .decay_s = 0.08 });
    synth.note(coin, rate, .{ .start_s = 0.07, .length_s = 0.25, .from_hz = 1319, .wave = .square, .amp = 0.25, .decay_s = 0.10 });
    synth.note(laser, rate, .{ .length_s = 0.18, .from_hz = 1800, .to_hz = 250, .wave = .saw, .amp = 0.30, .decay_s = 0.08 });
    synth.note(laser, rate, .{ .length_s = 0.12, .from_hz = 3600, .to_hz = 900, .amp = 0.10, .decay_s = 0.05 });
    synth.burst(boom, rate, .{ .length_s = 0.70, .amp = 0.70, .decay_s = 0.25, .smooth = 0.93, .seed = 1234 });
    synth.note(boom, rate, .{ .length_s = 0.45, .from_hz = 110, .to_hz = 40, .amp = 0.60, .decay_s = 0.15 });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var clip: [sound_frame_count]f32 = undefined;
    var wav: [synth.wavSize(sound_frame_count)]u8 = undefined;

    renderAll(&clip); // Warm up.
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    var checksum: f32 = 0;
    for (0..round_count) |_| {
        renderAll(&clip);
        checksum += clip[sound_frame_count / 2];
    }
    const render_ns: f64 = @floatFromInt(start.untilNow(io).raw.nanoseconds);

    const wav_start: std.Io.Clock.Timestamp = .now(io, .awake);
    for (0..round_count) |_| std.mem.doNotOptimizeAway(synth.writeWav(&clip, rate, &wav));
    const wav_ns: f64 = @floatFromInt(wav_start.untilNow(io).raw.nanoseconds);
    std.mem.doNotOptimizeAway(checksum);

    const sound_s = @as(f64, sound_frame_count) / rate;
    const render_ms = render_ns / round_count / std.time.ns_per_ms;
    std.debug.print("render {d:.2} s of sound: {d:.3} ms, {d:.2} s of sound per ms\n", .{ sound_s, render_ms, sound_s / render_ms });
    std.debug.print("writeWav of the same: {d:.3} ms\n", .{wav_ns / round_count / std.time.ns_per_ms});
}
