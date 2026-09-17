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
