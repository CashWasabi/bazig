//! A thin wrapper over the engine of miniaudio.
//! miniaudio decodes WAV, FLAC and MP3.
//!
//! ```zig
//! var engine: audio.Engine = undefined;
//! try engine.init(.{});
//! defer engine.deinit();
//!
//! // Fire and forget:
//! try engine.playFile("click.wav");
//!
//! // Or keep a handle to control playback:
//! var music: audio.Sound = undefined;
//! try music.init(&engine, "music.mp3", .{ .stream = true });
//! defer music.deinit();
//! music.setLooping(true);
//! try music.start();
//! ```
//!
//! `Engine` and `Sound` are initialised in place.
//! miniaudio keeps pointers into them, so they must not be moved or copied after `init`.
//! A `Sound` is deinitialised before the `Engine` it was made from.
//!
//! miniaudio allocates inside `Engine.init` and `Sound.init`, through the C allocator.
//! `deinit` frees it.
const std = @import("std");
const assert = std.debug.assert;
const c = @import("miniaudio_c");

pub const Error = error{
    InvalidArgs,
    InvalidOperation,
    OutOfMemory,
    AccessDenied,
    DoesNotExist,
    InvalidFile,
    FormatNotSupported,
    NoBackend,
    NoDevice,
    DeviceNotInitialized,
    FailedToInitBackend,
    /// Any other miniaudio `ma_result` error code.
    Unexpected,
};

fn check(result: c.ma_result) Error!void {
    return switch (result) {
        c.MA_SUCCESS => {},
        c.MA_INVALID_ARGS => error.InvalidArgs,
        c.MA_INVALID_OPERATION => error.InvalidOperation,
        c.MA_OUT_OF_MEMORY => error.OutOfMemory,
        c.MA_ACCESS_DENIED => error.AccessDenied,
        c.MA_DOES_NOT_EXIST => error.DoesNotExist,
        c.MA_INVALID_FILE => error.InvalidFile,
        c.MA_FORMAT_NOT_SUPPORTED => error.FormatNotSupported,
        c.MA_NO_BACKEND => error.NoBackend,
        c.MA_NO_DEVICE => error.NoDevice,
        c.MA_DEVICE_NOT_INITIALIZED => error.DeviceNotInitialized,
        c.MA_FAILED_TO_INIT_BACKEND => error.FailedToInitBackend,
        else => error.Unexpected,
    };
}

pub const Engine = struct {
    raw: c.ma_engine,

    pub const Config = struct {
        /// Open no audio device.
        /// Audio then comes only from `readPcmFrames`.
        /// That serves tests and offline rendering.
        /// Set `channels` and `sample_rate` too.
        no_device: bool = false,
        /// How many output channels.
        /// 0 takes the device's own count.
        channels: u32 = 0,
        /// The output sample rate.
        /// 0 takes the device's own rate.
        sample_rate: u32 = 0,
    };

    /// Opens the engine and starts it.
    pub fn init(self: *Engine, config: Config) Error!void {
        assert(!config.no_device or (config.channels > 0 and config.sample_rate > 0));
        var cfg = c.ma_engine_config_init();
        cfg.noDevice = @intFromBool(config.no_device);
        cfg.channels = config.channels;
        cfg.sampleRate = config.sample_rate;
        try check(c.ma_engine_init(&cfg, &self.raw));
    }

    /// Closes the engine.
    /// Every `Sound` made from it is deinitialised first.
    pub fn deinit(self: *Engine) void {
        c.ma_engine_uninit(&self.raw);
        self.* = undefined;
    }

    /// Starts the audio device again after `stop`.
    /// `init` already starts it.
    /// An engine without a device returns `error.InvalidOperation`.
    pub fn start(self: *Engine) Error!void {
        try check(c.ma_engine_start(&self.raw));
    }

    /// Stops the audio device.
    /// An engine without a device returns `error.InvalidOperation`.
    pub fn stop(self: *Engine) Error!void {
        try check(c.ma_engine_stop(&self.raw));
    }

    /// Sets the master volume.
    /// 1.0 leaves it unchanged.
    pub fn setVolume(self: *Engine, new_volume: f32) Error!void {
        try check(c.ma_engine_set_volume(&self.raw, new_volume));
    }

    /// The master volume.
    pub fn volume(self: *Engine) f32 {
        return c.ma_engine_get_volume(&self.raw);
    }

    /// How many output channels.
    pub fn channels(self: *Engine) u32 {
        return c.ma_engine_get_channels(&self.raw);
    }

    /// The output sample rate.
    pub fn sampleRate(self: *Engine) u32 {
        return c.ma_engine_get_sample_rate(&self.raw);
    }

    /// Plays a file or registered data once, with no handle.
    /// The sound is freed when it ends.
    pub fn playFile(self: *Engine, path: [:0]const u8) Error!void {
        try check(c.ma_engine_play_sound(&self.raw, path.ptr, null));
    }

    /// Makes the bytes of a whole encoded file playable under `name`.
    /// A WAV, say.
    /// `playFile` and `Sound.init` then take `name` in place of a path.
    /// A sound with `.stream` does not, because miniaudio streams from the file system.
    /// The bytes are not copied.
    /// They outlive every play, until `unregisterData`.
    /// That is how a game carries its sounds inside the binary.
    pub fn registerData(self: *Engine, name: [:0]const u8, bytes: []const u8) Error!void {
        try check(c.ma_resource_manager_register_encoded_data(c.ma_engine_get_resource_manager(&self.raw), name.ptr, bytes.ptr, bytes.len));
    }

    /// Forgets the data registered under `name`.
    /// It does not free the bytes.
    /// A sound still playing from them goes on using them, and the name still works meanwhile.
    /// Keep the bytes until every such sound has ended or the engine is gone.
    pub fn unregisterData(self: *Engine, name: [:0]const u8) void {
        _ = c.ma_resource_manager_unregister_data(c.ma_engine_get_resource_manager(&self.raw), name.ptr);
    }

    /// Mixes interleaved frames into `out`, and returns how many it made.
    /// It is for an engine with `no_device`.
    /// Otherwise the audio device pulls the frames.
    /// The engine makes nothing while no sound plays, so the count can be below `out.len / channels`.
    /// The rest of `out` is silence.
    /// `out.len` is a multiple of the channel count.
    pub fn readPcmFrames(self: *Engine, out: []f32) Error!usize {
        const channel_count = self.channels();
        assert(channel_count > 0);
        assert(out.len % channel_count == 0);
        const frame_count = out.len / channel_count;
        var frames_read: u64 = 0;
        try check(c.ma_engine_read_pcm_frames(&self.raw, out.ptr, frame_count, &frames_read));
        const read: usize = @intCast(frames_read);
        @memset(out[read * channel_count ..], 0);
        return read;
    }
};

pub const Sound = struct {
    raw: c.ma_sound,

    pub const Flags = struct {
        /// Stream from disk instead of loading the whole file.
        /// For long files, such as music.
        /// miniaudio opens a stream from the file system, so it takes a real path.
        /// A name from `registerData` returns `error.DoesNotExist`.
        stream: bool = false,
        /// Decode to PCM up front.
        /// It costs more memory and is cheap to play.
        /// For short effects that play often.
        decode: bool = false,
        /// Skip 3D positioning.
        /// For 2D audio.
        no_spatialization: bool = false,

        /// As miniaudio's bit flags.
        fn toC(flags: Flags) u32 {
            return @as(u32, @intFromBool(flags.stream)) * c.MA_SOUND_FLAG_STREAM |
                @as(u32, @intFromBool(flags.decode)) * c.MA_SOUND_FLAG_DECODE |
                @as(u32, @intFromBool(flags.no_spatialization)) * c.MA_SOUND_FLAG_NO_SPATIALIZATION;
        }
    };

    /// Loads a file or registered data.
    /// The sound starts stopped.
    /// `start` plays it.
    pub fn init(self: *Sound, engine: *Engine, path: [:0]const u8, flags: Flags) Error!void {
        try check(c.ma_sound_init_from_file(&engine.raw, path.ptr, flags.toC(), null, null, &self.raw));
    }

    /// Frees the sound, before the engine.
    pub fn deinit(self: *Sound) void {
        c.ma_sound_uninit(&self.raw);
        self.* = undefined;
    }

    /// Starts or resumes playback.
    pub fn start(self: *Sound) Error!void {
        try check(c.ma_sound_start(&self.raw));
    }

    /// Pauses playback.
    /// `start` resumes from the same place.
    pub fn stop(self: *Sound) Error!void {
        try check(c.ma_sound_stop(&self.raw));
    }

    /// Moves playback back to the first frame.
    pub fn seekToStart(self: *Sound) Error!void {
        try check(c.ma_sound_seek_to_pcm_frame(&self.raw, 0));
    }

    /// Whether the sound is playing.
    pub fn isPlaying(self: *Sound) bool {
        return c.ma_sound_is_playing(&self.raw) != 0;
    }

    /// Whether playback has reached the end of the data.
    /// Never for a looping sound.
    pub fn atEnd(self: *Sound) bool {
        return c.ma_sound_at_end(&self.raw) != 0;
    }

    /// Sets whether the sound starts over at its end.
    pub fn setLooping(self: *Sound, looping: bool) void {
        c.ma_sound_set_looping(&self.raw, @intFromBool(looping));
    }

    /// Whether the sound starts over at its end.
    pub fn isLooping(self: *Sound) bool {
        return c.ma_sound_is_looping(&self.raw) != 0;
    }

    /// Sets the linear volume.
    /// 1.0 leaves it unchanged.
    pub fn setVolume(self: *Sound, new_volume: f32) void {
        c.ma_sound_set_volume(&self.raw, new_volume);
    }

    /// The linear volume.
    pub fn volume(self: *Sound) f32 {
        return c.ma_sound_get_volume(&self.raw);
    }

    /// Sets how fast it plays, which also shifts the pitch.
    /// 1.0 leaves it unchanged.
    pub fn setPitch(self: *Sound, pitch: f32) void {
        c.ma_sound_set_pitch(&self.raw, pitch);
    }

    /// Sets the stereo pan.
    /// -1.0 is left and 1.0 is right.
    pub fn setPan(self: *Sound, pan: f32) void {
        c.ma_sound_set_pan(&self.raw, pan);
    }
};

const testing = std.testing;
const synth = @import("synth.zig");

const tone_frame_count = 480;
const tone_rate = 48_000;
const ToneBuffer = [synth.wavSize(tone_frame_count)]u8;

/// A WAV file of `tone_frame_count` samples, all of them `value`.
/// It is a hundredth of a second of a steady level.
fn toneWav(buffer: *ToneBuffer, value: f32) []u8 {
    const samples: [tone_frame_count]f32 = @splat(value);
    return synth.writeWav(&samples, tone_rate, buffer);
}

const no_device: Engine.Config = .{ .no_device = true, .channels = 2, .sample_rate = tone_rate };

fn peakOf(samples: []const f32) f32 {
    var highest: f32 = 0;
    for (samples) |sample| highest = @max(highest, @abs(sample));
    return highest;
}

test "engine without a device" {
    var engine: Engine = undefined;
    try engine.init(no_device);
    defer engine.deinit();

    try testing.expectEqual(@as(u32, 2), engine.channels());
    try testing.expectEqual(@as(u32, 48_000), engine.sampleRate());

    try engine.setVolume(0.5);
    try testing.expectEqual(@as(f32, 0.5), engine.volume());

    // Nothing is playing so no frames are produced and the buffer is silenced.
    var out: [256]f32 = undefined;
    @memset(&out, 1);
    try testing.expectEqual(@as(usize, 0), try engine.readPcmFrames(&out));
    for (out) |sample| try testing.expectEqual(@as(f32, 0), sample);
}

test "play a sound file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var wav_buf: ToneBuffer = undefined;
    const wav = toneWav(&wav_buf, 0.5);
    try tmp.dir.writeFile(io, .{ .sub_path = "tone.wav", .data = wav });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, ".zig-cache/tmp/{s}/tone.wav", .{tmp.sub_path}, 0);

    var engine: Engine = undefined;
    try engine.init(no_device);
    defer engine.deinit();

    var sound: Sound = undefined;
    try sound.init(&engine, path, .{ .decode = true, .no_spatialization = true });
    defer sound.deinit();

    try testing.expect(!sound.isPlaying());
    sound.setVolume(0.25);
    try testing.expectEqual(@as(f32, 0.25), sound.volume());
    sound.setLooping(true);
    try testing.expect(sound.isLooping());
    sound.setLooping(false);

    try sound.start();
    try testing.expect(sound.isPlaying());

    // The file holds 480 frames, so rendering 1024 must run it to the end.
    var out: [2048]f32 = undefined;
    try testing.expectEqual(@as(usize, 1024), try engine.readPcmFrames(&out));

    var peak: f32 = 0;
    for (out) |sample| peak = @max(peak, @abs(sample));
    try testing.expect(peak > 0);
    try testing.expect(sound.atEnd());
}

test "registered in-memory data plays by name, like a real file would" {
    var wav_buf: ToneBuffer = undefined;
    const wav = toneWav(&wav_buf, 0.5);

    var engine: Engine = undefined;
    try engine.init(no_device);
    defer engine.deinit();

    try engine.registerData("tone", wav);
    defer engine.unregisterData("tone");

    try engine.playFile("tone");

    // The file holds 480 frames, so rendering 1024 must run it to the end, exactly as a real file
    // played the same way would (see "play a sound file").
    var out: [2048]f32 = undefined;
    try testing.expectEqual(@as(usize, 1024), try engine.readPcmFrames(&out));

    var peak: f32 = 0;
    for (out) |sample| peak = @max(peak, @abs(sample));
    try testing.expect(peak > 0);
}

test "missing file is an error" {
    var engine: Engine = undefined;
    try engine.init(no_device);
    defer engine.deinit();

    var sound: Sound = undefined;
    try testing.expectError(error.DoesNotExist, sound.init(&engine, "does/not/exist.wav", .{}));
}

test "the master volume scales what comes out" {
    var wav_buf: ToneBuffer = undefined;
    const wav = toneWav(&wav_buf, 0.5);
    var peaks: [2]f32 = undefined;
    for ([_]f32{ 1.0, 0.25 }, &peaks) |volume, *peak| {
        var engine: Engine = undefined;
        try engine.init(no_device);
        defer engine.deinit();
        try engine.registerData("tone", wav);
        defer engine.unregisterData("tone");
        try engine.setVolume(volume);
        try engine.playFile("tone");
        var out: [512]f32 = undefined;
        _ = try engine.readPcmFrames(&out);
        peak.* = peakOf(&out);
    }
    try testing.expect(peaks[0] > 0.1);
    try testing.expectApproxEqRel(@as(f32, 4), peaks[0] / peaks[1], 0.01);
}

test "a stopped sound is silent and goes on from where it was; seeking starts it over" {
    var wav_buf: ToneBuffer = undefined;
    const wav = toneWav(&wav_buf, 0.5);
    var engine: Engine = undefined;
    try engine.init(no_device);
    defer engine.deinit();
    try engine.registerData("tone", wav);
    defer engine.unregisterData("tone");
    var sound: Sound = undefined;
    try sound.init(&engine, "tone", .{ .decode = true, .no_spatialization = true });
    defer sound.deinit();

    var out: [400]f32 = undefined; // 200 frames at a time: the tone is 480 long
    try sound.start();
    _ = try engine.readPcmFrames(&out);
    try testing.expect(peakOf(&out) > 0.1);
    try sound.stop();
    try testing.expect(!sound.isPlaying());
    _ = try engine.readPcmFrames(&out);
    try testing.expectEqual(@as(f32, 0), peakOf(&out)); // nothing while it is stopped

    try sound.start(); // from frame 200: 280 are left
    _ = try engine.readPcmFrames(&out);
    try testing.expect(peakOf(&out) > 0.1);
    try testing.expect(!sound.atEnd());
    _ = try engine.readPcmFrames(&out);
    try testing.expect(sound.atEnd());

    try sound.seekToStart();
    try sound.start();
    _ = try engine.readPcmFrames(&out);
    try testing.expect(peakOf(&out) > 0.1); // all of it again
    try testing.expect(!sound.atEnd());
}

test "a looping sound keeps going past its end" {
    var wav_buf: ToneBuffer = undefined;
    const wav = toneWav(&wav_buf, 0.5);
    var engine: Engine = undefined;
    try engine.init(no_device);
    defer engine.deinit();
    try engine.registerData("tone", wav);
    defer engine.unregisterData("tone");
    var sound: Sound = undefined;
    try sound.init(&engine, "tone", .{ .decode = true, .no_spatialization = true });
    defer sound.deinit();
    sound.setLooping(true);
    try sound.start();
    var out: [2000]f32 = undefined; // 1000 frames a read, twice the tone's length
    for (0..3) |_| {
        _ = try engine.readPcmFrames(&out);
        try testing.expect(peakOf(out[1800..]) > 0.1); // still sounding at the end of every read
    }
    try testing.expect(sound.isPlaying());
    try testing.expect(!sound.atEnd());
}

test "a higher pitch plays faster: the sound is over sooner" {
    var wav_buf: ToneBuffer = undefined;
    const wav = toneWav(&wav_buf, 0.5);
    var over_after_300: [2]bool = undefined;
    for ([_]f32{ 1.0, 2.0 }, &over_after_300) |pitch, *over| {
        var engine: Engine = undefined;
        try engine.init(no_device);
        defer engine.deinit();
        try engine.registerData("tone", wav);
        defer engine.unregisterData("tone");
        var sound: Sound = undefined;
        try sound.init(&engine, "tone", .{ .decode = true, .no_spatialization = true });
        defer sound.deinit();
        sound.setPitch(pitch);
        try sound.start();
        var out: [600]f32 = undefined; // 300 frames of the 480
        _ = try engine.readPcmFrames(&out);
        over.* = sound.atEnd();
    }
    try testing.expectEqual([2]bool{ false, true }, over_after_300);
}

test "panning moves the sound to one side" {
    var wav_buf: ToneBuffer = undefined;
    const wav = toneWav(&wav_buf, 0.5);
    var engine: Engine = undefined;
    try engine.init(no_device);
    defer engine.deinit();
    try engine.registerData("tone", wav);
    defer engine.unregisterData("tone");
    var sound: Sound = undefined;
    try sound.init(&engine, "tone", .{ .decode = true, .no_spatialization = true });
    defer sound.deinit();
    sound.setPan(1.0); // all the way right
    try sound.start();
    var out: [400]f32 = undefined;
    _ = try engine.readPcmFrames(&out);
    var left_peak: f32 = 0;
    var right_peak: f32 = 0;
    for (0..200) |frame| {
        left_peak = @max(left_peak, @abs(out[frame * 2]));
        right_peak = @max(right_peak, @abs(out[frame * 2 + 1]));
    }
    try testing.expect(right_peak > 0.1);
    try testing.expect(left_peak < right_peak * 0.05);
}

test "data that is no longer registered cannot be played; an engine without a device cannot stop or start" {
    var wav_buf: ToneBuffer = undefined;
    const wav = toneWav(&wav_buf, 0.5);
    var engine: Engine = undefined;
    try engine.init(no_device);
    defer engine.deinit();
    try engine.registerData("tone", wav);
    engine.unregisterData("tone"); // nothing is playing it: the name is gone at once
    try testing.expectError(error.DoesNotExist, engine.playFile("tone"));
    try engine.registerData("tone", wav); // and can be registered again
    try engine.playFile("tone");
    engine.unregisterData("tone");
    // with no device there is nothing to stop or start
    try testing.expectError(error.InvalidOperation, engine.stop());
    try testing.expectError(error.InvalidOperation, engine.start());
}

test "a stream reads the file system, so it cannot play registered data" {
    var wav_buf: ToneBuffer = undefined;
    const wav = toneWav(&wav_buf, 0.5);
    var engine: Engine = undefined;
    try engine.init(no_device);
    defer engine.deinit();
    try engine.registerData("tone", wav);
    defer engine.unregisterData("tone");
    var sound: Sound = undefined;
    try testing.expectError(error.DoesNotExist, sound.init(&engine, "tone", .{ .stream = true }));
}

test "the flags become miniaudio's bits" {
    try testing.expectEqual(@as(u32, 0), (Sound.Flags{}).toC());
    try testing.expectEqual(@as(u32, c.MA_SOUND_FLAG_STREAM), (Sound.Flags{ .stream = true }).toC());
    try testing.expectEqual(@as(u32, c.MA_SOUND_FLAG_DECODE | c.MA_SOUND_FLAG_NO_SPATIALIZATION), (Sound.Flags{ .decode = true, .no_spatialization = true }).toC());
}
