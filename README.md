# sane-airscan on macOS

A macOS port of [sane-airscan](https://github.com/alexpevzner/sane-airscan),
plus the glue needed to make a **WSD-only network scanner** appear in Image
Capture, Preview, and anything else built on Apple's ImageCapture
framework.

There is no macOS support in sane-airscan upstream. This repository is a
patch against it, not a fork.

## Symptoms this solves


Your network MFP prints fine but **won't scan from a Mac**. It doesn't
appear in Image Capture. It shows up in Printers & Scanners with no Scan
tab, or with "no scanner detected". The manufacturer's macOS software is
32-bit, discontinued, or never existed, and the spec sheet says nothing
about **AirPrint Scanning** or **AirScan**. On Windows the same device
scans without trouble.

If that sounds familiar, the cause is usually a protocol mismatch rather
than anything broken.

## Is this for you?

macOS speaks exactly one network scanning protocol: **eSCL**, marketed as
AirScan. If your scanner supports eSCL, macOS already sees it and you do
not need any of this.

Plenty of network MFPs from roughly 2010–2015 support only **WSD** (Web
Services for Devices, Microsoft's equivalent, layered on the PWG Scan
Model). macOS cannot talk to them at all, and for devices out of firmware
support that will never change. They print fine over AirPrint or IPP and
simply cannot be scanned from.

This bridges that gap:

```
scanner ──WSD──> sane-airscan ──> SANE ──> AirSane ──eSCL/Bonjour──> macOS
                 (ported here)             (upstream, builds on macOS)
```

sane-airscan implements WSD but is Linux/BSD-only — the patch here ports
it to Darwin. [AirSane](https://github.com/SimulPiscator/AirSane) then
re-publishes the SANE device over Bonjour as an eSCL scanner, which is
what macOS understands.

The same path works for an eSCL scanner that macOS cannot reach for other
reasons (wrong subnet, mDNS blocked), since sane-airscan supports both
protocols.

## Requirements

- Apple Silicon or Intel Mac with [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`)
- A scanner on the same subnet as the Mac — WS-Discovery is multicast and
  does not route between VLANs or across guest SSIDs

## Install

```bash
./build-macos.sh
```

This installs Homebrew dependencies, clones sane-airscan, applies the
patch, builds and installs the backend, then builds and installs AirSane
as a LaunchDaemon. Expect a few minutes on a first run; the `sudo` prompt
is for the daemon and its config under `/usr/local`.

The halves are independent — `./build-macos.sh airscan` gives you a working
`scanimage` on the command line with no daemon and no `sudo` beyond
Homebrew. `./build-macos.sh airsane` adds the macOS-facing bridge.

### Upstream revisions are pinned

`macos-port.patch` is a context diff, so it is tied to specific upstream
revisions. The build script pins both sane-airscan and AirSane to the
commits this port is verified against, which is what makes a clone
reproducible rather than dependent on the day you cloned it.

To check whether the port still applies to current upstream:

```bash
AIRSCAN_REF=origin/master ./build-macos.sh airscan
```

If the patch no longer applies the script says so and stops, without
touching your installed backend. That means the patch needs rebasing —
please open an issue, ideally naming the hunks that failed.

## Verify, in order

Each step isolates one layer. If a step fails, the ones after it cannot
work, so don't skip ahead.

**1. Does sane-airscan see the scanner?**

```bash
airscan-discover
```

Expect a `[devices]` block naming it with a `WSD` (or `eSCL`) endpoint URL.
This is WS-Discovery multicast and does not involve Bonjour.

**2. Does SANE see it?**

```bash
scanimage -L
```

Expect `device 'airscan:w0:<your scanner>' is a WSD <your scanner>`.

**3. Does it scan?**

```bash
scanimage -d "$(scanimage -L | head -1 | cut -d\' -f2)" \
          --format=png --resolution 300 > ~/Desktop/test-scan.png
```

**4. Does macOS see it?**

```bash
dns-sd -B _uscan._tcp                                   # Bonjour advert
curl -s http://127.0.0.1:8090/eSCL/ScannerCapabilities  # eSCL endpoint
```

Then open Image Capture — the scanner should be in the sidebar, and in
System Settings → Printers & Scanners as a Bonjour Scanner.

## Troubleshooting

**`airscan-discover` finds nothing.** A network problem, not a build one.
Check that the scanner and Mac share a subnet; allow the binary through
the macOS firewall when prompted; confirm WSD is enabled in the scanner's
embedded web server (often under Networking → Advanced → Web Services).
Failing that, skip discovery entirely — copy `airscan.conf.template` over
your `airscan.conf` (see below) and enter the device URL by hand.

**`scanimage -L` finds nothing while AirSane is running.** You are running
a backend built before the `SO_REUSEPORT` fix. Two processes cannot share
the WS-Discovery port without it on macOS, so the daemon locks everyone
else out silently. Rebuild and reinstall the backend.

**Image Capture shows nothing, and `/eSCL/ScannerCapabilities` returns
404.** AirSane registered no scanner. Check the log:

```bash
grep -E 'found:|ignoring|published' /var/log/airsaned.log
```

`ignoring airscan:...` means AirSane's ignore list matched your device —
see `airsane-ignore.conf`, which this repo installs to fix exactly that.

**Everything breaks after `brew upgrade sane-backends`.** Homebrew's
libsane has its config and backend directories compiled in as *versioned
Cellar paths*, so an upgrade orphans both. Re-run `./build-macos.sh
airscan`.

**Configuration file locations.** Not where you would expect on Homebrew —
`$(brew --prefix)/etc/sane.d` holds only symlinks, and libsane never reads
it. The real path is:

```bash
echo "$(pkg-config --variable=prefix sane-backends)/etc/sane.d"
```

## Scope and limitations

**eSCL mDNS browsing is deliberately not implemented.** avahi is a Linux
daemon with no macOS build, so that discovery path is compiled out. WSD
discovery is a separate code path that never used avahi and is unaffected.
The practical effect is that an eSCL scanner will not be *auto-discovered*
on macOS, though it still works if configured manually. Implementing this
over Bonjour would be a reasonable contribution.

**Hostname resolution is real, not stubbed.** WSD discovery yields
hostnames that must be resolved, so returning nothing would break
auto-discovery outright. It uses `getaddrinfo(3)` on a worker thread,
which on macOS resolves `.local` through mDNSResponder.

**The Linux and BSD paths are untouched.** Every change sits behind a
platform conditional.

## Tested

Developed against an **HP LaserJet Pro 200 color MFP M276nw** (WSD-only,
last firmware 2012) on Apple Silicon, macOS 26. Verified end to end:
discovery, `scanimage -L`, a 300 dpi colour scan, Bonjour advertisement,
and Image Capture.

Only that one device and OS version have been tested. The port is not
scanner-specific — nothing in it knows about the M276nw — so other WSD
scanners are expected to work, but reports either way are welcome.

## Repository contents

| Path | What it is |
|---|---|
| `macos-port.patch` | The port itself, against sane-airscan `master`. ~1,700 lines across 11 files. |
| `build-macos.sh` | Dependencies, clone, patch, build, install, for both halves. |
| `airsaned.plist` | LaunchDaemon for AirSane, with logging the stock one lacks. |
| `airsane-ignore.conf` | AirSane device ignore list, narrowed so WSD devices are not blacklisted. |
| `airscan.conf.template` | Manual device entry, for when multicast discovery is unavailable. |
| `test-compat-eloop.c` | Standalone test for the avahi-replacement event loop. |
| `PORTING.md` | Technical notes: what the patch does, what broke, what is still unverified. |

## Licence

sane-airscan is **GPL-2.0-or-later**, so this patch — a derivative work —
is under the same terms. See `LICENSE`.

`build-macos.sh` fetches sane-airscan and AirSane from their own
repositories at build time; neither is redistributed here.

## Upstreaming

This has not been submitted upstream. The platform-conditional structure
was kept with that in mind, and `PORTING.md` documents the reasoning behind
each decision. The `SO_REUSEPORT` fix in particular is a genuine
Linux/BSD portability bug that is worth upstreaming on its own.
