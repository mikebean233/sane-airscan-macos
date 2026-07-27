# CLAUDE.md

Guidance for Claude Code and similar agents working in this repository.

## What this is

A macOS port of sane-airscan, distributed as a patch (`macos-port.patch`)
rather than a fork. `README.md` covers installation and troubleshooting;
`PORTING.md` has the technical detail. **Read `PORTING.md` before
debugging anything** — it records which hypotheses have already been
tested and disproven, and re-deriving them wastes time.

## Ground rules

- **Keep the Linux and BSD paths untouched.** Every change is behind a
  platform conditional, and it must stay that way. The intent is to be
  upstreamable.
- **Do not drop `-Werror`.** The upstream Makefile hardcodes it and the
  build is warning-free under Apple clang. Fix warnings; don't silence
  them.
- **`OS_HAVE_*` macros belong at the top of `airscan.h`.** They select the
  avahi-versus-compat include. Moving them lower breaks the build
  confusingly.
- **Fold changes back into `macos-port.patch`** before finishing. Work
  happens in `work/sane-airscan`, which is gitignored — a fix left only
  there is lost on the next clean run. See the last section of
  `PORTING.md` for the exact commands, including the `git add -N` step
  that untracked files need.

## Verifying a change

Build in `work/sane-airscan`, then confirm the patch still applies to a
pristine upstream tree — regenerating the patch is easy to get subtly
wrong:

```bash
git clone https://github.com/alexpevzner/sane-airscan.git /tmp/verify
cd /tmp/verify && git apply /path/to/macos-port.patch && make
```

Layered verification, in order, is described in `README.md`. Don't skip
ahead; each step depends on the one before.

## Things that look broken but aren't

- Homebrew's SANE names backends `libsane-<name>.<major>.so`, so
  `libsane-airscan.1.so` is correct and `.so.1` is not.
- The backend is a Mach-O dylib with a `.so` extension. This is
  deliberate; SANE's `dll` backend builds the filename literally.
- ld64 warns about symbols in `airscan.sym.darwin` it cannot find. Those
  warnings are harmless.
- The config directory is a versioned Homebrew Cellar path, not
  `$(brew --prefix)/etc/sane.d`. See `PORTING.md`.

## Hardware

Developed against a single WSD-only MFP. Nothing in the port is
scanner-specific, but only that one device has been tested — be careful
about presenting behaviour observed on it as general.
