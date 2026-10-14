# bazig

Game audio for Zig.
Play sound files, or make sound effects in code and play them with no files at all.
`bazig.audio` wraps the engine of [miniaudio](https://miniaud.io).
`bazig.synth` is a small synthesizer.
miniaudio is fetched and compiled in, so there is nothing to install.

```zig
const bazig = @import("bazig");
const synth = bazig.synth;

// Make a coin sound: two quick square-wave notes, the second a fourth up.
const rate = 22_050;
var clip: [rate / 4]f32 = @splat(0); // A quarter second of silence.
synth.note(&clip, rate, .{ .length_s = 0.08, .from_hz = 988, .wave = .square, .amp = 0.25, .decay_s = 0.08 });
synth.note(&clip, rate, .{ .start_s = 0.07, .length_s = 0.18, .from_hz = 1319, .wave = .square, .amp = 0.25, .decay_s = 0.10 });

// Wrap it as a WAV file in memory and play it by name.
var engine: bazig.audio.Engine = undefined;
try engine.init(.{});
defer engine.deinit();

var bytes: [synth.wavSize(clip.len)]u8 = undefined;
try engine.registerData("coin", synth.writeWav(&clip, rate, &bytes));
try engine.playFile("coin"); // The engine resamples to the device's rate.
```

[`examples/synth_sounds.zig`](examples/synth_sounds.zig) makes a coin, a laser and an explosion.
It writes them as WAV files and plays one from memory.

## Install

```sh
zig fetch --save git+https://github.com/CashWasabi/bazig#0.1.0
```

```zig
// build.zig
const bazig = b.dependency("bazig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("bazig", bazig.module("bazig"));
```

Needs Zig 0.17.
It links libc.
miniaudio loads the system audio libraries at run time, so nothing else needs linking.

Zig 0.17 has no `@cImport`.
So the first build compiles the `translate-c` package to read miniaudio's header.
That takes a few minutes, once.

Tested on x86-64 Linux, and on x86-64 Windows under wine.
The release CI also runs on macOS and Windows.
Not tested on mobile or the web.
Cross-compiling to macOS needs the macOS SDK for the CoreAudio headers.

## Playing sound: `bazig.audio`

An `Engine` opens the sound card and mixes everything that plays.
A `Sound` is a handle to one sound.
It starts, stops, loops, and sets volume, pitch and pan.
miniaudio decodes WAV, FLAC and MP3.

`Engine` and `Sound` are set up in place with `init`, because miniaudio keeps pointers into them.
Do not copy or move them afterwards.

```zig
var engine: bazig.audio.Engine = undefined;
try engine.init(.{});
defer engine.deinit();

try engine.playFile("click.wav"); // Fire and forget.

var music: bazig.audio.Sound = undefined; // Or keep a handle.
try music.init(&engine, "music.mp3", .{ .stream = true });
defer music.deinit(); // Before the engine.
music.setLooping(true);
try music.start();
```

### Sounds inside the binary

A game can carry its sounds inside the binary.
`registerData("coin", bytes)` makes the bytes of a whole WAV, FLAC or MP3 file playable as `"coin"`.
`playFile` and `Sound.init` take the name like a path.

The bytes are not copied.
Keep them alive until `unregisterData`, and until every sound playing them has ended.
A sound with `.stream = true` cannot use a name, because miniaudio streams from disk.

### No sound card

With `.no_device = true` the engine opens no sound card.
Set `channels` and `sample_rate` too.
Then pull the mixed audio yourself with `readPcmFrames`.
Use it for tests, for rendering to a file, and on machines with no audio.
Such an engine has nothing to `start` or `stop`, and both return `error.InvalidOperation`.

## Making sound: `bazig.synth`

A clip is a `[]f32` of mono samples in -1..1, at a sample rate you choose.
Start from silence and add to it.
Every call adds to what is already there, and drops what falls past the end.

`note(clip, sample_rate, .{ ... })` adds a note.
Short fades at both ends stop it clicking.

| Field | Meaning | Default |
| --- | --- | --- |
| `length_s` | how long it lasts | required |
| `from_hz` | pitch at the start | required |
| `to_hz` | pitch at the end, gliding from `from_hz` | `from_hz` |
| `decay_s` | seconds until it is down to 37% | required |
| `wave` | `sine`, `square`, `saw` or `triangle` | `sine` |
| `amp` | loudness at the start, 0..1 | 1 |
| `start_s` | when it starts in the clip | 0 |

`burst(clip, sample_rate, .{ ... })` adds a burst of noise.
It makes hits, explosions and wind.

| Field | Meaning | Default |
| --- | --- | --- |
| `length_s` | how long it lasts | required |
| `decay_s` | seconds until it is down to 37% | required |
| `smooth` | 0 is bright hiss, near 1 is a dull rumble | 0 |
| `seed` | which noise; the same seed gives the same burst | 1 |
| `amp` | loudness at the start, 0..1 | 1 |
| `start_s` | when it starts in the clip | 0 |

`writeWav(clip, sample_rate, buffer)` writes the clip as a mono 16-bit WAV file and returns its bytes.
`buffer` holds `wavSize(clip.len)` bytes.
Samples are clipped to -1..1.
Hand the bytes to `registerData`, or write them to disk.

`synth` allocates nothing.
The caller passes the clip and the WAV buffer.

It is also deterministic.
The noise is an xorshift, not a system random.
The same call gives the same samples, bit for bit, in Debug and in release builds.
So a sound can be tested like any other function.
For example, count zero crossings to check its pitch.

## What it costs

1.2 s of sound renders in about 1.5 ms, around 800 times faster than real time.
So a game can make all its effects at start-up.

| What | Cost |
| --- | --- |
| Render the three sounds of the example, 1.2 s of sound | 1.25 to 1.6 ms |
| `writeWav` of the same | about 0.03 ms |

Measured with `zig build bench`.
ReleaseFast, Ryzen 7 2700U, 2026-10-14.

miniaudio allocates inside `Engine.init` and `Sound.init`, through the C allocator.
`deinit` frees it.

## Build

```sh
zig build test      # 23 tests
zig build example   # examples/synth_sounds.zig, checks its own results
zig build bench     # examples/bench.zig, the numbers above
```

The tests need no sound card.

## Versions

bazig follows [Semantic Versioning](https://semver.org/).
Before 1.0 a minor release may break the API.
Every break is listed in [CHANGELOG.md](CHANGELOG.md).
The rules and the release steps are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT.
See [LICENSE](LICENSE).

miniaudio is public domain or MIT-0, at your choice.
See its [LICENSE](https://github.com/mackron/miniaudio/blob/0.11.25/LICENSE).
