#!/bin/bash
# Build sane-airscan with the macOS port patch, plus the AirSane bridge.
#
#   ./build-macos.sh            build and install everything
#   ./build-macos.sh airscan    only sane-airscan
#   ./build-macos.sh airsane    only AirSane
#
# Upstream revisions are pinned (see below). To try a newer upstream:
#
#   AIRSCAN_REF=master ./build-macos.sh airscan
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"
STEP="${1:-all}"

# ---------------------------------------------------------------------
# Pinned upstream revisions
# ---------------------------------------------------------------------
# macos-port.patch is context-sensitive: it is a diff against specific
# versions of these files. Tracking a moving master would mean that a
# clone made today and one made next month build differently, and that an
# upstream edit near any patched hunk breaks the build for everyone with
# no warning and no way to get back to a known-good state.
#
# These are the revisions the patch is verified against -- it applies
# cleanly and builds warning-free with -Werror.
#
# Overriding these is supported and encouraged when checking whether the
# port still applies to current upstream; see PORTING.md. If `git apply'
# then fails, the patch needs rebasing, not the pin removing.
AIRSCAN_REPO="https://github.com/alexpevzner/sane-airscan.git"
AIRSCAN_REF="${AIRSCAN_REF:-9da18d88c88f542671b24fc0433dd7d69dcb0132}"

# AirSane is not patched, but its build files, default ignore.conf and
# LaunchDaemon plist all matter to us, so pin it for reproducibility too.
AIRSANE_REPO="https://github.com/SimulPiscator/AirSane.git"
AIRSANE_REF="${AIRSANE_REF:-129cc3bf7258251a0a694dee7741285b59d88f9f}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

command -v brew >/dev/null || {
    echo "Homebrew is required: https://brew.sh" >&2; exit 1; }

BREW_PREFIX="$(brew --prefix)"
export PKG_CONFIG_PATH="$BREW_PREFIX/opt/libxml2/lib/pkgconfig:$BREW_PREFIX/opt/libtiff/lib/pkgconfig:$BREW_PREFIX/opt/jpeg-turbo/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

say "Installing dependencies"
brew install sane-backends libxml2 gnutls jpeg-turbo libpng libtiff pkg-config cmake git

mkdir -p "$WORK"

# checkout_pinned <dir> <repo-url> <ref>
#
# Clone if needed, then hard-reset to the pinned revision. Clean as well
# as reset: `git apply' refuses to create a file that already exists, so
# the files the patch adds have to be gone before it runs, and stale
# build output would otherwise be reused across a ref change.
checkout_pinned() {
    local dir="$1" repo="$2" ref="$3"

    [ -d "$dir" ] || git clone "$repo" "$dir"
    cd "$dir"

    # Only hit the network when the ref is not already available, so that
    # a repeat build works offline.
    if ! git cat-file -e "$ref^{commit}" 2>/dev/null; then
        say "Fetching $ref"
        git fetch --quiet origin || {
            echo "error: cannot fetch $ref from $repo" >&2; exit 1; }
    fi

    git checkout --quiet --force --detach "$ref" 2>/dev/null || {
        echo "error: no such revision in $repo: $ref" >&2
        echo "       (a branch name needs fetching: try AIRSCAN_REF=origin/master)" >&2
        exit 1; }
    git clean -fdqx

    echo "    $(basename "$dir") at $(git log -1 --format='%h %ad %s' --date=short)"
}

if [ "$STEP" = all ] || [ "$STEP" = airscan ]; then
    say "Fetching sane-airscan"
    checkout_pinned "$WORK/sane-airscan" "$AIRSCAN_REPO" "$AIRSCAN_REF"

    say "Applying macOS port patch"
    if ! git apply --check "$HERE/macos-port.patch" 2>/dev/null; then
        cat >&2 <<EOF

error: macos-port.patch does not apply to $(git rev-parse --short HEAD).

If you overrode AIRSCAN_REF, upstream has moved away from the revision
this port was written against and the patch needs rebasing -- see the
"Working on the patch" section of PORTING.md. Reports of which hunks
broke are welcome.

To build the known-good combination instead, unset AIRSCAN_REF.
EOF
        exit 1
    fi
    git apply --verbose "$HERE/macos-port.patch"

    say "Building sane-airscan"
    make

    say "Installing sane-airscan"
    make install

    say "sane-airscan installed"
fi

if [ "$STEP" = all ] || [ "$STEP" = airsane ]; then
    say "Fetching AirSane (eSCL bridge, so macOS sees a normal scanner)"
    checkout_pinned "$WORK/AirSane" "$AIRSANE_REPO" "$AIRSANE_REF"

    # Our LaunchDaemon plist, in place of the stock one. cmake installs
    # this file verbatim (no substitution), so it has to be swapped in
    # the source tree before `make install'. See airsaned.plist for why
    # it differs.
    cp "$HERE/airsaned.plist" \
       "$WORK/AirSane/launchd/org.simulpiscator.airsaned.plist"

    say "Building AirSane"
    rm -rf "$WORK/AirSane-build"
    mkdir -p "$WORK/AirSane-build"
    cd "$WORK/AirSane-build"
    cmake ../AirSane
    make

    say "Installing AirSane"
    sudo make install

    # AirSane's stock ignore.conf blacklists "airscan:.*" to avoid
    # re-exporting eSCL scanners macOS can already see. That would ignore
    # our WSD device too -- the one thing we need it to export. cmake
    # only installs this file if it does not already exist, so overwrite
    # it unconditionally. See airsane-ignore.conf.
    sudo cp "$HERE/airsane-ignore.conf" /usr/local/etc/airsane/ignore.conf

    say "Starting AirSane"
    # bootout first so a re-run restarts cleanly rather than failing with
    # "service already loaded"
    sudo launchctl bootout system/org.simulpiscator.airsaned 2>/dev/null || true
    sudo launchctl bootstrap system \
        /Library/LaunchDaemons/org.simulpiscator.airsaned.plist

    say "AirSane installed and running"
    echo "Startup takes ~10s (it opens the scanner to enumerate options)."
    echo "Log: /var/log/airsaned.log"
fi

say "Done. Next: run 'airscan-discover' to find the printer."
