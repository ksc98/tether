# Upstream review log

Every rebase of this fork onto `zackb/tether` gets an entry here: what
upstream added, whether it was read, what was found, and the verdict. The
point is that nothing lands in the fork unread, and that a later decision to
send something upstream, or to drop something of ours in favour of theirs,
starts from a written record instead of a re-read.

Verdicts: **absorb** (take as is), **absorb, with fix** (take it, fork carries
a fix noted below and meant for upstream), **keep ours** (upstream's version is
not taken, reason given).

## 2026-09-22: `9f9d1f2` → `779b8a4` (17 commits, 39 files)

Read in full: `248b958`, `620a631`, `eb60a58`, `afcb136`, `24c3d9d`,
`dee9bea`, `c7387cf`. Version bumps, merges and the flatpak doc change were
skimmed. Upstream's test suite (`ctest`, debug preset) was run on the rebased
tree: 7 failures (`DiscoveryTest.StateCallbackReportsOnlyChanges`, four
`HeadlessRuntime.*`, two `DialogRejection.*`), identical on a pristine
`upstream/main` worktree on the same machine, so they are environmental
(this shell has no Wayland session and no dialog binary), not from the
rebase.

### `248b958` feat: image clipboard transfer — absorb, with fix

What it does: the Wayland reader takes `image/png` when no text MIME is
offered (`pick_clipboard_mime`), caches PNG bytes beside the text, and the
daemon sends an image as a `file_start`/`file_chunk`/`file_end` transfer
tagged `"clipboard": "updated"|"content"` to sessions that announced
`clipboard_image` in a new `hello` message. The app answers `hello`, sends its
own images the same way tagged `"set"`, and writes received PNGs to the
pasteboard. 32 MB cap, PNG signature check, size check on completion, one
receiver per session, tests for the MIME pick and the receiver.

Read for: cache coherence between text and image, echo suppression, the
fallback for clients without the feature, memory and locking.

- Cache: an image selection sets the image cache and leaves the text cache
  alone; a text selection clears the image cache; `copy_to_clipboard` (text
  from a peer) clears the image cache, `copy_image_to_clipboard` primes the
  image cache first so the compositor's echo is not rebroadcast. Sound.
- `clipboard_send` refuses to push the stale text while an image is selected.
  **`clipboard_get` does not**: a session without the image feature (the
  fork's Shortcuts intents, `tether paste`, any older client) gets the text
  from before the image was copied, presented as current. The fork carries a
  fix (empty `content` while an image is selected) as its own commit for
  upstream.
- `broadcast_clipboard_image` holds `g_sessions_mutex` while writing up to
  32 MB of base64 to each session's TLS socket. The same pattern as
  `broadcast_message`, so no regression, but a slow phone now blocks every
  other broadcast for longer. Noted, not changed.
- The Wayland pipe read happens on the event loop in 64 KiB pieces. Fine for
  32 MB.
- Text wins over image when both are offered. Browsers copying an image
  usually offer `image/png` plus `text/html` and no `text/plain`, so the image
  is picked. Correct for the common case.

Fork impact: `WaylandContext` gained `set_clipboard_image_callback`; the
fork's Bluetooth write hangs off the text callback only, so an image copy
sends nothing over Bluetooth yet. Follow-up in
[BLUETOOTH-CLIPBOARD.md](BLUETOOTH-CLIPBOARD.md) (limits section).

### `620a631` fix: stale or pending pairing requests are not cleaned — absorb

Pending Wi-Fi pairing requests get a timestamp and a one-hour TTL, pruned on
read. Old string-valued entries are migrated. Tested.

### `eb60a58` fix: improve mdns discovery — absorb

Despite the title this changes no publishing: it stores the last discovered
peer list so `tether status` and the GTK app can show it. Harmless. The
periodic `mDNS: Published` log line every 20 s is unchanged.

### `afcb136` fix(ios): app does not readvertise mdns after foregrounding — absorb

The app restarts its listener on `.active`, and an incoming connection is now
accepted while the app is in `connecting` or `pairing` (it cancels the
outbound attempt). Matches what the desktop side already did.

### `24c3d9d` + `dee9bea` fix(bluetooth): harden container pairing retries — absorb

Pairing resolves the device object live (`GetManagedObjects`) before each
attempt instead of trusting the debounced monitor snapshot, since a failed
`Connect()` can make BlueZ drop and recreate `Device1`. The agent's accepted
device path follows. `probe_secure_connections` falls back to a
`TETHER_BLUEZ_SECURE_CONNECTIONS` environment flag when `btmgmt` is
unavailable (containers). The review round removed a `PreferredBearer`
override that the first version had added. Tests cover the flag parsing and
the path refresh. No effect on cachy's existing bond.

### `c7387cf` feat: "Copy Code" OTP notification marks message as read — absorb

Desktop-side only.

### Fork changes made during this rebase

- `TetherMessage.swift`: the fork's `bt_clipboard_advertise` cases were added
  and later removed in the fork's own history; both edits conflicted with
  upstream's new `hello` case and were resolved to upstream's enum plus the
  fork's final state (no advertise cases).
- `BluezMonitor::invoke_async` (fork) sits beside upstream's
  `environment_flag` change in `monitor.cpp`. No overlap.

## Branch layout for upstreaming

- `shortcuts-clipboard-intents`: the two App Intents, one commit on
  `upstream/main`.
- `bluetooth-clipboard`: the Bluetooth push, on top of the intents branch
  (it reuses `ShareSender.fetchClipboard`). Daemon, app, spec, Sync Clipboard.
- `clipboard-get-stale-text`: one daemon fix, `clipboard_get` behind an image.
- `intent-endpoint-port`: one app fix, the stored daemon address after an
  inbound session carried the daemon's ephemeral dial port, so the Share
  Extension and the intents dialled a closed port.
- `kyle`: everything above plus fork-only tooling (CI workflow, justfile,
  sideload entitlements, these docs). Never sent upstream as is.

To open an upstream PR: rebase the feature branch on `upstream/main`, push
it, PR from there. `kyle` is re-derived after each upstream rebase, so a
feature branch and `kyle` can drift in commit ids but not in content.
