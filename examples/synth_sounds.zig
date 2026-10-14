//! Game sounds made in code with `bazig.synth`, and played by the audio engine.
//!
//! It renders a coin, a laser and an explosion from notes and noise.
//! It writes each as a WAV file to listen to.
//! Then it registers the explosion with an `audio.Engine` under a name and plays it by that name.
//! That is how a game ships its sounds inside the binary.
//! The engine has `no_device` and is read back, so this runs with or without a sound card.
//! It checks its own results.
//!
//!     zig build example     # Writes coin.wav, laser.wav and boom.wav to zig-out/sounds.
//!     synth_sounds [dir]    # Writes them to `dir`, by default the current directory.
const std = @import("std");
const bazig = @import("bazig");
const synth = bazig.synth;

const rate: u32 = 22_050;

/// A coin: two quick square-wave notes, the second a fourth higher.
fn coin(out: []f32) void {
    synth.note(out, rate, .{ .length_s = 0.07, .from_hz = 988, .wave = .square, .amp = 0.25, .decay_s = 0.08 });
    synth.note(out, rate, .{ .start_s = 0.07, .length_s = 0.25, .from_hz = 1319, .wave = .square, .amp = 0.25, .decay_s = 0.10 });
}

/// A laser: a saw sweeping down fast, with a thin sine on top.
fn laser(out: []f32) void {
    synth.note(out, rate, .{ .length_s = 0.18, .from_hz = 1800, .to_hz = 250, .wave = .saw, .amp = 0.30, .decay_s = 0.08 });
    synth.note(out, rate, .{ .length_s = 0.12, .from_hz = 3600, .to_hz = 900, .amp = 0.10, .decay_s = 0.05 });
}

/// An explosion: low-passed noise (`smooth` near 1 is duller) over a falling thump.
fn boom(out: []f32) void {
    synth.burst(out, rate, .{ .length_s = 0.70, .amp = 0.70, .decay_s = 0.25, .smooth = 0.93, .seed = 1234 });
    synth.note(out, rate, .{ .length_s = 0.45, .from_hz = 110, .to_hz = 40, .amp = 0.60, .decay_s = 0.15 });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_path = if (args.len > 1) args[1] else ".";
    try std.Io.Dir.cwd().createDirPath(io, out_path);
    var out_dir = try std.Io.Dir.cwd().openDir(io, out_path, .{});
    defer out_dir.close(io);

    const sounds = [_]struct { name: []const u8, seconds: f32, render: *const fn ([]f32) void }{
        .{ .name = "coin.wav", .seconds = 0.32, .render = coin },
        .{ .name = "laser.wav", .seconds = 0.18, .render = laser },
        .{ .name = "boom.wav", .seconds = 0.70, .render = boom },
    };

    var boom_wav: []u8 = &.{};
    defer gpa.free(boom_wav);
    for (sounds) |sound| {
        // 1. Render: start from silence and add notes and bursts into it.
        const frame_count: usize = @intFromFloat(@ceil(sound.seconds * @as(f32, @floatFromInt(rate))));
        const samples = try gpa.alloc(f32, frame_count);
        defer gpa.free(samples);
        @memset(samples, 0);
        sound.render(samples);
        const sound_peak = peak(samples);
        if (sound_peak < 0.1 or sound_peak > 1) return error.BadLevel;

        // 2. Wrap as a WAV file (mono, 16-bit): these bytes are what the engine and any player take.
        const bytes = try gpa.alloc(u8, synth.wavSize(frame_count));
        const wav = synth.writeWav(samples, rate, bytes);
        if (wav.len != synth.wavSize(frame_count)) return error.BadWav;
        try out_dir.writeFile(io, .{ .sub_path = sound.name, .data = wav });
        std.debug.print("wrote {s}/{s}: {d} samples, {d} bytes, peak {d:.2}\n", .{ out_path, sound.name, frame_count, wav.len, sound_peak });
        if (std.mem.eql(u8, sound.name, "boom.wav")) boom_wav = bytes else gpa.free(bytes);
    }

    // 3. Play from memory: register the bytes under a name, then play that name like a file.
    var engine: bazig.audio.Engine = undefined;
    try engine.init(.{ .no_device = true, .channels = 1, .sample_rate = rate });
    defer engine.deinit();
    try engine.registerData("boom", boom_wav); // Not copied: the bytes must outlive every play.
    defer engine.unregisterData("boom");
    try engine.playFile("boom");

    // With a real device the sound card pulls the audio; here we pull it ourselves.
    var mixed: [4096]f32 = undefined;
    const frames_read = try engine.readPcmFrames(&mixed);
    const mixed_peak = peak(mixed[0..frames_read]);
    std.debug.print("played \"boom\" from memory: first {d} frames mixed, peak {d:.2}\n", .{ frames_read, mixed_peak });
    if (frames_read != mixed.len or mixed_peak < 0.1) return error.Silent;
}

fn peak(samples: []const f32) f32 {
    var highest: f32 = 0;
    for (samples) |sample| highest = @max(highest, @abs(sample));
    return highest;
}
