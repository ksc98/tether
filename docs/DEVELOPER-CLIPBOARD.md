# Developer clipboard (proposal)

Two-way clipboard sync with no Tether app involvement on the phone: tetherd
reads and writes the iPhone's general pasteboard directly through the
developer services iOS exposes to a paired Mac, and keeps doing so across
phone restarts and Wi-Fi drops without user action. This document is the
specification for an opt-in mode for users who have Developer Mode on. It is
a proposal: the parts marked **unverified** must be settled by the spike at
the end before any tetherd code is written.

## Goal

Copy on the Linux desktop and the text or image is on the iPhone's clipboard
within a second, with the phone locked in a pocket and no tap. Copy on the
phone and it lands on the desktop clipboard. After the phone restarts, sync
resumes by itself once the phone is unlocked for the first time.

## Why a separate mode

The app-based paths ([BLUETOOTH-CLIPBOARD.md](BLUETOOTH-CLIPBOARD.md), the
Wi-Fi mTLS connection) are bounded by `UIPasteboard`: an app can read or
write it only while frontmost, so a background delivery ends in a
notification with a Copy action. The developer services are not an app: they
are what Xcode uses to drive a device, and they include a pasteboard service
with no foreground requirement. The price is developer setup on the phone,
which is why this is opt-in and never the default.

## Requirements on the phone

- **Developer Mode on** (Settings → Privacy & Security → Developer Mode,
  restart, confirm). iOS refuses to enable it remotely on a phone with a
  passcode; a host can only reveal the toggle (AMFI `action` 0).
- **Trusted host and RemotePairing record**, created once over USB: the
  lockdown pairing (Trust prompt) plus a RemotePairing pairing (a second Trust
  prompt) through the USB tunnel's `com.apple.internal.dt.coredevice.untrusted.tunnelservice`.
  After that everything runs over Wi-Fi.
- **The Developer Disk Image mounted.** Without it the phone's service
  directory (RSD) lists no `com.apple.coredevice.*` services at all, the
  pasteboard service included. Checked on iOS 27.2: 64 services over the
  Wi-Fi tunnel, none of them CoreDevice, but
  `com.apple.mobile.mobile_image_mounter.shim.remote` is present.

## Transport

All in process, no root, no TUN device, no `usbmuxd` after pairing:

1. **Discovery**: mDNS `_remotepairing._tcp`. The phone advertises under its
   private Wi-Fi address, so records are matched by trying them, not by MAC.
2. **RemotePairing**: TCP to that port, pair-verify with the stored record
   (Ed25519 identity, X25519 session key), then `create_tcp_listener`.
3. **Tunnel**: connect to the listener, TLS-PSK keyed by the session key. The
   stream carries IPv6 packets; the phone assigns client and server addresses.
4. **Userspace TCP** over those packets (the `jktcp` stack inside idevice),
   then **RSD** (RemoteServiceDiscovery, RemoteXPC over HTTP/2) on the
   announced port: the directory of services and their ports.
5. Services are TCP connections to their RSD ports through the tunnel.

Over USB the tunnel comes from the lockdown service CoreDeviceProxy instead;
iOS refuses CoreDeviceProxy over Wi-Fi lockdown, which is why Wi-Fi needs
RemotePairing.

## Mounting the Developer Disk Image

iOS 17 and later use the **personalized** image: one image for all devices,
signed per device and per boot by Apple's TSS server.

- **Files** (three): `Image.dmg`, its trust cache (`Image.dmg.trustcache`) and
  `BuildManifest.plist`. They ship with Xcode; a Mac that has run Xcode keeps
  them under `/Library/Developer/DeveloperDiskImages/iOS_DDI/` (path to be
  confirmed on the fork's build Mac). They are Apple's files: the user copies
  them from their own Xcode install; Tether does not redistribute them.
- **Signing**: `mobile_image_mounter` `QueryPersonalizationIdentifiers` and
  `QueryNonce`, a TSS request built from the manifest (the device's ECID and
  the nonce), the returned ticket, then upload and `MountImage` with the
  signature. idevice implements the whole sequence:
  `MobileImageMounterClient::mount_personalized_rsd` (through the tunnel) or
  `mount_personalized` (lockdown), with `get_manifest_from_tss`.
- **Lifetime**: the mount lasts until the phone reboots. The ticket is tied to
  the boot nonce, so each boot needs a fresh TSS request: **the host needs
  internet access once per phone boot.** Caching a ticket across boots is not
  expected to work (unverified).
- `lookup_image` reports whether a developer image is already mounted, so a
  mount is only attempted when needed.

## The pasteboard service

`com.apple.coredevice.pasteboardservice`, RemoteXPC (XPC dictionaries,
`command` field). idevice client: `services/core_device/pasteboard_service.rs`
(`PasteboardServiceClient`). Verbs (request → reply):

| verb | reply | use |
|---|---|---|
| `PULL` | `PULL_REPLY` | read the pasteboard (`get`, `get_with_policy`) |
| `SET` | `SET_REPLY` | replace it (`set_text`, `set_image`) |
| `RESOLVE` | `DATA` | fetch the bytes of a promised item (`resolve`) |
| `AUTONOTIFY` + `PUSH` | | subscribe to changes (`set_change_notifications`, `recv_push`) |

An item is `{types: [UTI], data: {UTI: PasteboardItemData}}`; data is inline
(`{data: <bytes>}`), promised (`{size: <Int64>}`, fetch with `RESOLVE`) or an
error. Text UTIs: `public.utf8-plain-text`, `public.plain-text`,
`public.text`; images: `public.png`, `public.jpeg`, `public.tiff`. The
pasteboard name is `general`.

## Behaviour

**Desktop → phone.** tetherd already watches the Wayland clipboard. In this
mode each new desktop selection (text, or a PNG) is written with `SET`.
Writes that originated from the phone (below) are not echoed back.

**Phone → desktop.** tetherd subscribes with `AUTONOTIFY` and waits on
`PUSH`. On a push it reads the snapshot (resolving promised items up to a
size cap), sets the desktop clipboard, and remembers a hash of the content to
suppress the echo from its own next `SET`.

**Loop prevention** by content hash on both directions, plus a short window
after each write in which an identical change from the other side is
ignored.

## Lifecycle and recovery

tetherd owns a small state machine per phone:

| state | leaves when |
|---|---|
| `unpaired` | the user runs the one-time USB pairing |
| `searching` | mDNS finds the phone and pair-verify succeeds |
| `tunnel-up` | RSD lists `com.apple.coredevice.pasteboardservice`, or the mount below succeeds |
| `mounting` | the personalized mount succeeds (TSS reachable) |
| `syncing` | the tunnel or a service connection drops |

- **Tunnel drop** (Wi-Fi roam, phone asleep for hours, reboot): back to
  `searching`, retrying with backoff; clipboard changes on the desktop during
  the gap are kept (latest only) and written on reconnect.
- **Reboot detection**: a reboot unmounts the image and resets the phone's
  uptime. The first successful connection after a drop checks
  `lookup_image`; if nothing is mounted it goes through `mounting` again.
- **Before first unlock** the phone is not on Wi-Fi at all (iOS 27.2,
  checked over a 90 s locked wait): its address answers neither ARP nor ping,
  lockdown is not advertised, and only a cached `_remotepairing._tcp` record
  may still resolve, so connecting to it fails. The host cannot tell a
  restarted phone from one that is out of range, so tetherd stays in
  `searching` and reports "phone unreachable: if it restarted, unlock it
  once", retrying quietly. It connects on its own within seconds of the first
  unlock. This is the one step the user cannot skip.
- **No internet at boot**: stay in `mounting` with a clear status and retry;
  sync resumes when TSS answers.

## Architecture in tetherd

tetherd is C/C++; the whole stack above is in the Rust `idevice` crate.
idevice ships C and C++ bindings (`ffi/`, `cpp/`), but the bindings do not
cover the CoreDevice pasteboard service. Two options:

1. **Rust helper process** (recommended): a small binary (`tether-devlink`)
   that owns discovery, pairing records, the tunnel, the mount and the
   pasteboard client, and speaks a line-delimited JSON protocol to tetherd
   over a Unix socket (`set_text`, `set_image`, `changed` events, `status`).
   Crashes and reconnect loops stay out of tetherd; tetherd spawns and
   restarts it.
2. Extend idevice's FFI with the pasteboard client and link it into tetherd.
   More integration surface in C++ for the same behaviour.

Pairing records: the lockdown record and the RemotePairing record, mode 0600.
Tether's existing app pairing (self-signed mTLS certificates, Bluetooth) is a
separate system and is unaffected. When another tool on the same machine has
already paired the phone this way, the helper should read that tool's records
rather than pair again: no second Trust prompt, and no question of whether a
second pairing from the same host replaces the first (iOS keeps a list of
paired hosts, so a separate pairing is expected to coexist, but that is
unverified). Otherwise it pairs itself and stores the records under
`$XDG_DATA_HOME/tether/`.

## Security

Mounting the Developer Disk Image enables every developer service on the
phone (screenshots, app install and launch, location simulation, process
control) for any host holding a pairing record, until the next reboot. The
pairing records are the key: store them 0600, never sync them. The mode is
off by default and documented as a developer feature.

## Unverified (the spike settles these)

1. The personalized mount works over the Wi-Fi tunnel (`mount_personalized_rsd`)
   on iOS 27.2, as it does for Xcode's wireless debugging.
2. `com.apple.coredevice.pasteboardservice` appears in RSD once mounted.
3. `PULL`, `SET` (text and PNG) and `AUTONOTIFY`/`PUSH` work, including with
   the phone locked, and without a "pasted from" banner or a rate limit.
4. The ticket cannot be reused after a reboot (so TSS is needed per boot).
5. The mount survives the phone locking and sleeping, until reboot.

## Spike

From Linux, with idevice directly (no tetherd changes):

1. Copy the three image files from the build Mac's Xcode (read-only there).
2. Open the Wi-Fi tunnel with an existing RemotePairing record, list RSD
   services, and record whether any CoreDevice service is present.
3. `lookup_image`, then `mount_personalized_rsd`; list RSD again.
4. With `PasteboardServiceClient`: `get("general")`, `set_text`, `set_image`,
   then subscribe and copy on the phone; repeat with the phone locked.
5. Reboot the phone, unlock it, confirm the image is gone and re-mounts.

Record each result in this document, then decide between the two
architectures and start the helper.
