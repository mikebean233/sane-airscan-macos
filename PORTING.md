# Porting notes

Technical detail behind `macos-port.patch`: what the patch changes, which
assumptions turned out to be wrong, and what remains unverified. Aimed at
anyone extending this, debugging it on different hardware, or preparing it
for upstream.

For installation and troubleshooting, see `README.md`.

## Design decisions

**mDNS browsing is stubbed, not implemented.** The avahi-client surface
(browsing over D-Bus) has no macOS equivalent, and it only finds eSCL
devices — which macOS discovers by itself. Reimplementing it over Bonjour
would be worthwhile for completeness but is not needed for the WSD case
this port exists to serve.

**Hostname resolution is deliberately *not* stubbed.** `airscan-wsdd.c`
needs it to turn a WSD-discovered hostname into an address, so returning
nothing would silently break auto-discovery. It uses `getaddrinfo(3)` on a
detached worker thread; on macOS that resolves `.local` through
mDNSResponder.

**`OS_HAVE_*` macros live at the top of `airscan.h`** because they select
the avahi-versus-compat include. Moving them lower breaks the build in a
confusing way.

**The compat event loop rebuilds its pollfd array every `prepare()`.**
Upstream `eloop.c` works around an avahi assertion when a watch is added
during dispatch by returning `EBUSY` from the poll hook. The compat loop
does not have that bug, but the `EBUSY` path is harmless and was left in
place for Linux.

## What the patch changes

| File | Change |
|---|---|
| `airscan-compat-avahi.{c,h}` | **New.** Reimplements the avahi-common subset over `poll(2)`: the `avahi_simple_poll` event loop, the `AvahiPoll`/`Watch`/`Timeout` vtable, domain and address helpers. Also Darwin shims for `pipe2`, `SOCK_CLOEXEC`/`SOCK_NONBLOCK`, `MSG_NOSIGNAL` → `SO_NOSIGPIPE`, `memrchr`, and `<endian.h>` macros via `OSSwap*`. |
| `airscan.h` | OS feature detection moved to the top of the file and extended with an `__APPLE__` branch. Adds `<stdarg.h>`, and renames `uuid_parse` on Darwin. |
| `airscan-mdns.c` | avahi-client browsing behind `#ifdef OS_HAVE_AVAHI`; Darwin branch resolves hostnames via `getaddrinfo` on a worker thread. |
| `airscan-eloop.c`, `airscan-http.c` | Direct `<avahi-common/*.h>` includes guarded. |
| `airscan-wsdd.c` | `SO_REUSEPORT` on the WS-Discovery socket where the platform needs it. |
| `airscan-os.c` | `os_progname()` via `_NSGetExecutablePath()`. Previously `#error FIX ME` on Darwin. |
| `airscan.c` | Mach-O has no symbol aliases; Darwin gets real forwarding functions. |
| `Makefile` | Darwin branch: Homebrew prefix, keg-only `PKG_CONFIG_PATH`, `-dynamiclib`, `-exported_symbols_list`, `-D__APPLE_USE_RFC_3542`, backend filename, `CONFDIR`, no `install -s`. |
| `airscan.sym.darwin` | ld64-format export list generated from `airscan.sym`. |

## Compile errors and their fixes

Recorded so they are not re-derived. All were in code no Apple toolchain
had previously compiled.

1. **`aliases are not supported on darwin`** (13×, `airscan.c`) — Mach-O
   has no symbol aliases. Behind `OS_HAVE_SYMBOL_ALIAS`; on Darwin the
   `sane_airscan_*` entry points are real functions forwarding to `sane_*`.
2. **`va_start` undeclared** (`airscan-conf.c`) — glibc pulls in
   `<stdarg.h>` transitively; Darwin does not. Added to `airscan.h`.
3. **`avahi-common/*.h` not found** — `airscan-eloop.c` and
   `airscan-http.c` included avahi headers unconditionally.
4. **`memrchr` undeclared** (`airscan-http.c`) — GNU extension. Added
   `compat_memrchr`, gated on `OS_HAVE_MEMRCHR`.
5. **`conflicting types for 'uuid_parse'`** — Darwin's `<uuid/uuid.h>`,
   pulled in by `<pwd.h>`, declares its own with a different signature.
   `airscan.h` includes it first so that declaration is processed under
   its real name, then renames ours to `airscan_uuid_parse` on Darwin.
6. **`IPV6_RECVPKTINFO`/`IPV6_PKTINFO` undeclared** (`airscan-wsdd.c`) —
   Darwin hides the RFC 3542 API behind `-D__APPLE_USE_RFC_3542`, which
   must be defined before `<netinet/in.h>`, hence the Makefile.

The `socket()` macro in `airscan-compat-avahi.h` — which redefines
`socket()` so existing call sites need no edits, and which looks like the
most fragile thing in the patch — caused no trouble. The header includes
`<sys/socket.h>` before defining the macro, which is sufficient.

`-Werror` is intact and the build is warning-free under Apple clang.

## `SO_REUSEPORT`: a Linux/BSD divergence

`airscan-wsdd.c` set only `SO_REUSEADDR` on the WS-Discovery socket. On
Linux that is enough for several processes to bind UDP 3702. **The BSDs,
Darwin included, require `SO_REUSEPORT`** — and every socket sharing the
port must set it, including the first to bind.

The symptom is nasty. Once a long-running consumer starts (an AirSane
daemon, say), every other user of the backend on the machine silently
finds nothing: `scanimage -L` and `airscan-discover` return empty lists
with no error and no log line. It looks exactly like the scanner
disappearing from the network.

Fixed behind `OS_NEEDS_SO_REUSEPORT` (Darwin and BSD). This is a genuine
portability bug rather than a macOS quirk, and is worth upstreaming
independently of the rest of the port.

## Homebrew install layout

Two non-obvious details, both of which produce silent failure.

**Backend filename.** SANE's `dll` backend builds the name it `dlopen`s
from the pattern `%s/libsane-%s.%u.so` — major version *last but one*.
Homebrew's own backends follow this (`libsane-dll.1.so`), so the Darwin
build produces **`libsane-airscan.1.so`**, not `libsane-airscan.so.1`. The
extension stays `.so`: it is a Mach-O dylib, but `dll` builds the name
literally and Mach-O does not care about extensions.

**Config directory.** libsane has its config directory compiled in, and
under Homebrew that is the *versioned Cellar* path. `$(brew --prefix)/etc/sane.d`
holds only per-file symlinks into it and has no `dll.d/` at all, so a
backend registered there is never loaded — `scanimage -L` simply reports
no scanners. `CONFDIR` on Darwin therefore comes from `pkg-config
--variable=prefix sane-backends`, mirroring how `libdir` is derived.

A consequence of both: `brew upgrade sane-backends` moves the Cellar path
and orphans the backend and its config. Reinstall after any upgrade.

**`install -s`** runs `strip`, which fails on a Mach-O dylib whose exports
come from an `-exported_symbols_list`. `STRIP` is empty on Darwin.

## AirSane integration

**AirSane ignores sane-airscan devices by default.** Its stock
`ignore.conf` is:

```
escl:.*
airscan:.*
```

The reasoning is sound: a scanner sane-airscan reaches over eSCL is
already an AirScan device, so re-exporting it would advertise a redundant
copy of something macOS can see by itself. But it also excludes WSD
devices, which are the only ones that *need* exporting. The daemon logs
`ignoring airscan:w0:...` and serves 404 on `/eSCL/ScannerCapabilities`.

`airsane-ignore.conf` narrows the rule to `airscan:e.*`, keeping loop
protection for eSCL while letting WSD through. sane-airscan names devices
`airscan:e<n>:<name>` for eSCL and `airscan:w<n>:<name>` for WSD.

This is easy to misdiagnose. Running `airsaned` by hand appears to work,
because its default `--ignore-list=/etc/airsane/ignore.conf` does not
exist so no rules apply, while the LaunchDaemon passes
`/usr/local/etc/airsane/ignore.conf`, which does. The difference between
working and not working is which ignore list gets read — not privileges,
not networking.

**The stock LaunchDaemon plist logs nowhere.** With no `StandardOutPath`,
a daemon that finds no scanner gives no clue why. `airsaned.plist` adds
logging to `/var/log/airsaned.log` and a 30-second `ThrottleInterval` —
startup takes around ten seconds because AirSane opens the scanner to
enumerate options, and with `KeepAlive` and the 10-second default a
crash-looping daemon would hammer the device.

**Local-network privacy is not the problem**, despite being the obvious
suspect on recent macOS. A root LaunchDaemon probes over multicast and
receives responses normally; the log shows `200 OK` coming back from the
scanner. Do not pursue this without evidence from the log.

## Verified and unverified

**Verified** on Apple Silicon, macOS 26, Apple clang:

- Builds with `-Werror`, zero warnings. `libsane-airscan.1.so` is an arm64
  Mach-O dylib exporting all 27 symbols.
- `test-uri` and all seven `test-zeroconf` cases pass. `test-zeroconf`
  drives the compat `avahi_simple_poll` loop, so the event loop is
  exercised on real Darwin `poll(2)`.
- `airscan-discover`, `scanimage -L`, and a 300 dpi colour scan — between
  them exercising `_NSGetExecutablePath`, `compat_socket`, `SO_NOSIGPIPE`,
  the `AF_ROUTE` netif path, WSD multicast, and the `getaddrinfo` branch
  in `airscan-mdns.c`.
- `scanimage -L` working concurrently with a running AirSane daemon,
  confirming the `SO_REUSEPORT` fix.
- AirSane publishing the device over Bonjour, and Image Capture using it.

**Verified on Linux** with the Darwin path forced on, clean under
AddressSanitizer and UBSan (`test-compat-eloop.c`): watch dispatch,
timeout firing, one-shot semantics, re-arming, `watch_free` without
use-after-free, cross-thread `quit`, domain helpers,
`avahi_address_snprint`, `avahi_elapse_time`.

**Unverified:**

- The `OSSwap*` endian macros. They compile, but no big-endian path is
  reachable on arm64 or x86-64 to prove the conversions.
- `compat_pipe2` beyond the `O_CLOEXEC`/`O_NONBLOCK` combination the event
  loop requests.
- The `airscan-mdns.c` refcount discipline under churn. Resolution works,
  but nothing has stressed device appear/disappear races. Two references
  are held (resolver list and worker thread), `mdns_query_unref` is called
  with `mdns_stub_mutex` held, and the callback fires *without* the mutex
  so it can re-enter the module.
- Intel Macs. The Makefile detects the Homebrew prefix, so this is
  expected to work, but it has not been run.
- Any scanner other than the one in `README.md`, and any macOS version
  other than 26.

## Upstream pinning

`build-macos.sh` pins both upstreams by commit (`AIRSCAN_REF`,
`AIRSANE_REF`), overridable by environment variable.

The patch is a context diff, so it is coupled to the exact text around
each hunk. Tracking a moving `master` would mean two clones a month apart
build differently, and an upstream edit anywhere near a patched hunk
breaks the build for everyone at once with no way back to a known-good
state.

The failure mode is at least benign: `git apply` is atomic, so a patch
that no longer fits is rejected wholesale rather than half-applied, and
the script runs `git apply --check` first so it fails before touching an
installed backend. The risk pinning actually buys down is subtler — an
upstream change that still *applies* but no longer means the same thing.

Re-verifying against current upstream is a normal maintenance task:

```bash
AIRSCAN_REF=origin/master ./build-macos.sh airscan
```

Bumping the pin means: run the above, fix any rejected hunks, rebuild,
re-run the layered verification in `README.md`, then update the default
in `build-macos.sh`. Note that upstream adding a new source file that
includes avahi headers directly would need the same `#ifdef
OS_HAVE_AVAHI` guard applied — that is how `airscan-eloop.c` and
`airscan-http.c` were missed the first time.

## Working on the patch

`build-macos.sh` clones into `work/sane-airscan` and applies the patch. To
iterate, edit in that tree and re-run `make` — then fold changes back:

```bash
cd work/sane-airscan
git add -N airscan-compat-avahi.c airscan-compat-avahi.h airscan.sym.darwin
git diff > ../../macos-port.patch
```

Untracked files must be `git add -N`'d or they will be missing from the
diff. Verify against a clean tree before committing:

```bash
git clone https://github.com/alexpevzner/sane-airscan.git /tmp/verify
cd /tmp/verify && git apply /path/to/macos-port.patch && make
```

Useful debugging: set `enable = true` under `[debug]` in `airscan.conf`
for backend logging, and pass `--debug=true` to `airsaned`. Both are
verbose; the backend logs to stderr, which the LaunchDaemon captures to
`/var/log/airsaned.log`.
