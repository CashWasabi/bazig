# Contributing

## Building and testing

Needs Zig 0.17.

```sh
zig build test                                      # every test, with no sound card
zig build test -Doptimize=ReleaseFast               # the synth must give the same samples optimised
zig fmt --check src examples build.zig build.zig.zon
zig build example                                   # writes three WAV files and checks them
zig build bench                                     # what a sound costs, always ReleaseFast
```

A change is ready when all of these pass.
The first build compiles the `translate-c` package.
That takes a few minutes.
Later builds reuse it.

## The code

- `std` and miniaudio only.
  `src/audio.zig` wraps the engine.
  `src/synth.zig` is pure Zig and needs no miniaudio.
- `synth` allocates nothing.
  The caller passes the clip and the WAV buffer.
- `synth` is deterministic.
  The same call gives the same samples, bit for bit, in every build mode.
  Its noise is an xorshift, never a system random.
- Every public function has a test.
  Tests need no sound card.
  They open the engine with `no_device` and read the mix back.
  A test's name says what it checks.
  - For the synth they check pitch, glide, fades, decay, that notes add, and noise by seed.
  - For the engine they check files and registered bytes, stop and resume, seeking, looping, pitch, pan and master volume.
    They also pin down that a stream cannot play registered bytes.
- Units go in names: `length_s`, `from_hz`, `sample_rate`.
- Name counts, indices and sizes apart.
  `frame_count` counts frames.
  `first_idx` is an index.
  A size is in bytes.
- Assert what the caller must get right, such as `sample_rate > 0`.
  An error is for what the world gets wrong, such as a missing file.
- A change that may cost time is measured with `zig build bench`.
  Compare against the old code in interleaved runs.
  Update the README's numbers with the machine and the date.
  Record the load average here.
  The numbers in the README for 0.1.0 were taken at a load average of 2.5.
- Use decl literals where the type is known.
  Write `var noise: Noise = .init(1);`, not `var noise = Noise.init(1);`.
- Doc comments say what a call does and what the caller must do.
  Comments in code say why.
- A change users notice goes into the README.
- Markdown puts every sentence on its own line.
  Keep sentences short.

## miniaudio

miniaudio is a dependency in `build.zig.zon`, pinned to an upstream tag and not modified.
To update it, fetch the new tag:

```sh
zig fetch --save=miniaudio https://github.com/mackron/miniaudio/archive/refs/tags/X.Y.Z.tar.gz
```

Update the version in the comment above it in `build.zig.zon`, in the README and in the changelog.
Run every check.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `<type>: <what changed>`.
A scope is optional: `fix(synth): ...`.

| Type | For | Next release |
| --- | --- | --- |
| `fix` | a bug fix | patch |
| `feat` | a new feature | minor |
| `feat!` or `fix!` | a change that breaks callers | minor at 0.x, then major |
| `docs` | documentation only | patch, if released |
| `perf` | faster, same behaviour | patch |
| `refactor`, `test`, `build`, `ci`, `chore` | no change users see | none |

A `BREAKING CHANGE:` line in the body counts like `!`.

## Versions

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- **Patch** (0.1.**x**): bug fixes, documentation and performance.
  Nothing you call changes.
- **Minor** (0.**x**.0): new features.
  While the major version is 0, a minor release may also break code.
  Each break is listed under **Changed** or **Removed** in the changelog.
- **Major** (**1**.0.0): when the API is stable.
  From then on only a major release breaks code.

The commits since the last tag decide the release.
Any breaking change means minor, or major after 1.0.
Otherwise any `feat` means minor.
Otherwise it is a patch.

## Changelog

Every change users notice gets a line in [CHANGELOG.md](CHANGELOG.md), in the same commit.
It goes under `## [Unreleased]`, below one of these headings:
**Added**, **Changed**, **Deprecated**, **Removed**, **Fixed**, **Security**.
The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Write the line for someone who uses the library.
Do not repeat the commit message.

## Releasing

Start from an up-to-date `main` with all checks passing.

1. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`.
   Add a new empty `## [Unreleased]` above it.
   Update the links at the bottom:
   ```
   [Unreleased]: https://github.com/CashWasabi/bazig/compare/X.Y.Z...HEAD
   [X.Y.Z]: https://github.com/CashWasabi/bazig/compare/<previous>...X.Y.Z
   ```
2. Set `.version = "X.Y.Z"` in `build.zig.zon`.
   Update the `zig fetch` line in the README's Install section.
3. Commit with `chore: release X.Y.Z`.
4. Tag it.
   The tag is annotated and has no `v`, so the README's `zig fetch ...#X.Y.Z` works:
   ```sh
   git tag -a X.Y.Z -m "bazig X.Y.Z"
   git push origin main X.Y.Z
   ```
5. Wait for the `release` workflow on GitHub to pass.
   It runs on every version tag.
   It checks that the tag is on `main`.
   Then it checks formatting, runs the tests and runs the example on Linux, macOS and Windows.
6. On GitHub, draft a release from the tag.
   Use that version's changelog section as the notes.

If the workflow fails, fix it in a new patch release.
Never move or delete a pushed tag.
Anyone who fetched it holds its hash.
