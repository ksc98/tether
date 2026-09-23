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

# Build the iOS app on a Mac over ssh and install it on the USB-connected
# iPhone. The same xcodebuild + ad-hoc signing as the CI workflow, without the
# runner: the Mac needs Xcode.app (`~/bin/xcodes install --latest` on m4m-1).
# Builds the working tree as it is, committed or not.
ios-build mac="home@m4m-1":
    #!/usr/bin/env bash
    set -euo pipefail
    export LD_LIBRARY_PATH="$HOME/.local/lib/swift-compat" PATH="$HOME/.local/share/swiftly/bin:$PATH"
    remote=tether-build
    rsync -a --delete --exclude DevBuild --exclude .build --exclude 'xcuserdata' \
        apple/ "{{mac}}:$remote/apple/"
    ssh "{{mac}}" bash -s <<'REMOTE'
        set -euo pipefail
        cd tether-build/apple
        dd=$HOME/tether-build/dd
        xcodebuild build -quiet \
            -project Tether.xcodeproj -scheme Tether -configuration Release \
            -destination 'generic/platform=iOS' -derivedDataPath "$dd" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
        app="$dd/Build/Products/Release-iphoneos/Tether.app"
        test -d "$app/Metadata.appintents"
        rm -rf "$app/PlugIns"
        codesign --force --sign - --entitlements Tether-sideload.entitlements "$app"
        rm -rf "$HOME/tether-build/ipa" && mkdir -p "$HOME/tether-build/ipa/Payload"
        cp -R "$app" "$HOME/tether-build/ipa/Payload/"
        (cd "$HOME/tether-build/ipa" && rm -f ../Tether.ipa && zip -qry ../Tether.ipa Payload)
        ls -la "$HOME/tether-build/Tether.ipa"
    REMOTE
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    scp -q "{{mac}}:tether-build/Tether.ipa" "$dir/Tether.ipa"
    xtool install --usb "$dir/Tether.ipa"
