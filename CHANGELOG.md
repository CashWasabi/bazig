# Changelog

## [Unreleased]

## [0.1.0] - 2026-10-14

First public release.

### Added

- `audio.Engine` opens a device, mixes and sets the master volume.
  `playFile` plays a file and forgets it.
  miniaudio decodes WAV, FLAC and MP3.
- `audio.Engine.registerData` makes encoded bytes playable by name, without a copy.
  `unregisterData` removes them.
- `audio.Engine.Config.no_device` opens no sound card.
  `readPcmFrames` then pulls the mixed audio.
- `audio.Sound` is a handle to one sound.
  It starts, stops, seeks to the start and loops.
  It sets volume, pitch and pan.
- `synth.note` adds a sine, square, saw or triangle note to a clip.
  It glides between two pitches and dies away.
- `synth.burst` adds a burst of low-passed noise.
  The same seed gives the same noise.
- `synth.writeWav` and `synth.wavSize` turn a clip into a mono 16-bit WAV file.
- miniaudio 0.11.25, fetched as a Zig package and compiled in.
- One example in `examples/`, run with `zig build example`.
- `zig build bench`.

[Unreleased]: https://github.com/CashWasabi/bazig/compare/0.1.0...HEAD
[0.1.0]: https://github.com/CashWasabi/bazig/releases/tag/0.1.0
