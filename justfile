# Fork-only recipes. The desktop side builds with the Makefile / CMake presets.

# Download the newest Xcode-built IPA from the fork's CI and install it on the
# USB-connected iPhone. xtool re-signs it with the local developer account.
ios-install branch="kyle":
    #!/usr/bin/env bash
    set -euo pipefail
    export LD_LIBRARY_PATH="$HOME/.local/lib/swift-compat" PATH="$HOME/.local/share/swiftly/bin:$PATH"
    run=$(gh run list --repo ksc98/tether --workflow ios-sideload.yml --branch {{branch}} \
        --status success --limit 1 --json databaseId -q '.[0].databaseId')
    [ -n "$run" ] || { echo "no successful ios-sideload run on {{branch}}" >&2; exit 1; }
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    gh run download "$run" --repo ksc98/tether -n Tether-ipa -D "$dir"
    xtool install --usb "$dir/Tether.ipa"

# Build the desktop side from this checkout as an Arch package and install it
# over tether-bin, so pacman keeps owning /usr/bin/tetherd. makepkg clones the
# current branch from the working tree, so commit first.
install:
    #!/usr/bin/env bash
    set -euo pipefail
    repo=$(git rev-parse --show-toplevel)
    branch=$(git rev-parse --abbrev-ref HEAD)
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    cp packaging/tether.install "$dir/"
    sed -e "s|^pkgname=.*|pkgname=tether-git|" \
        -e "s|^source=.*|source=(\"git+file://$repo#branch=$branch\")|" \
        -e "s|^install=.*|install=tether.install|" \
        PKGBUILD > "$dir/PKGBUILD"
    (cd "$dir" && makepkg -sf --noconfirm)
    # --ask 4 answers the tether-bin conflict prompt on the first install.
    sudo pacman -U --noconfirm --ask 4 "$dir"/tether-git-*.pkg.tar.*
    # A client respawns tetherd on demand; the old one keeps the old code until it exits.
    pkill -f '^tetherd' || true
    tether status >/dev/null 2>&1 || true

# Build the "Sync Clipboard" shortcut, sign it on a Mac that is signed into
# iCloud (`shortcuts sign` insists on that, so no CI runner can), and send it
# to the phone over Tether's file transfer. The app has to be open and
# connected over Wi-Fi. On the phone, open the file from the Files tab and
# Shortcuts imports it.
ios-shortcut mac bundle="XTL-E8FE8F29.net.jeedup.Tether" team="2DRNAXC5AQ":
    #!/usr/bin/env bash
    set -euo pipefail
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    python3 apple/shortcuts/make_sync_shortcut.py --bundle-id "{{bundle}}" --team-id "{{team}}" \
        -o "$dir/unsigned.shortcut"
    remote=$(ssh "{{mac}}" 'mktemp -d')
    scp -q "$dir/unsigned.shortcut" "{{mac}}:$remote/"
    ssh "{{mac}}" "shortcuts sign --mode anyone --input '$remote/unsigned.shortcut' --output '$remote/Sync Clipboard.shortcut'"
    scp -q "{{mac}}:$remote/Sync Clipboard.shortcut" "$dir/"
    ssh "{{mac}}" "rm -rf '$remote'"
    tether send "$dir/Sync Clipboard.shortcut"
