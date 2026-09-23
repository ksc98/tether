# Bluetooth clipboard push

Desktop clipboard changes reach the iPhone while the Tether app is in the
background, over the Bluetooth LE link the phone already keeps for
notification mirroring. This document is the specification: what the feature
promises, the constraints that shaped it, the protocol on the link, and the
behaviour of each side.

## Goal

Copy text on the Linux desktop and have it available on the iPhone with the
app closed, within a second, with one tap on the phone.

## iOS constraints that shape the design

- An app can read or write `UIPasteboard` only while it is the frontmost app.
  Calls from a backgrounded app return nil and write nothing. This is why
  delivery ends in a notification with a Copy action rather than a silent
  clipboard update: the tap brings the app to the front, and only then can it
  write the pasteboard.
- The Wi-Fi mTLS connection exists only while the app is in the foreground.
  The app closes it on `scenePhase == .background`, and iOS suspends the
  process shortly after. The Wi-Fi socket cannot wake the app.
- The iPhone holds an LE link to the desktop for ANCS (notification
  mirroring). The phone is the central on that link. iOS does not share it
  with an app's `CBCentralManager`: a `connect()` to the desktop from the app
  never completes, with or without the desktop advertising, and no ATT
  traffic appears on the link. The phone's own GATT server is reachable on
  that link, and iOS wakes an app that serves a characteristic when a client
  writes to it (`bluetooth-peripheral` background mode).
- iOS relaunches a terminated app for a `CBPeripheralManager` event when the
  manager was created with a restore identifier, unless the user force-quit
  the app and never opened it again.

## Roles

The roles mirror ANCS.

| Side | LE role | GATT role | Job |
|---|---|---|---|
| iPhone (Tether app) | central | server | serves the clipboard characteristic, shows the notification |
| Linux (tetherd) | peripheral | client | writes each clipboard change into the characteristic |

Nothing needs to be discovered or advertised. The phone is already connected,
and BlueZ enumerates the phone's GATT table on that link. When the app adds
the service, iOS indicates Service Changed to the bonded desktop and BlueZ
re-enumerates.

## Protocol

### Identifiers

| | UUID |
|---|---|
| Service (primary) | `467df1f1-c20a-448e-ba52-4c46bf02c66b` |
| Characteristic | `a643d06f-b1d0-40c0-8d71-a752b08e0abc` |

The characteristic has the `write` property and the
`writeEncryptionRequired` permission. The bond between phone and desktop
encrypts the link, so an unbonded peer in range cannot set the clipboard.

### Value

One write per desktop clipboard change. The value is UTF-8 JSON of at most
512 bytes (the ATT attribute limit):

```json
{"seq": 17, "len": 1832, "text": "The first part of the clipboard…"}
```

- `seq`: strictly increasing across daemon restarts: the larger of the
  previous `seq` + 1 and the wall clock in milliseconds. The phone ignores a
  value whose `seq` is not greater than the last one it applied (it remembers
  that across its own relaunches), so a redelivered or reordered write cannot
  regress the clipboard, and a restarted daemon is not mistaken for a replay.
- `len`: byte length of the full clipboard text on the desktop.
- `text`: the clipboard text, cut at a UTF-8 character boundary so that the
  whole document fits in 512 bytes. JSON escaping counts toward the limit.

The phone treats the text as complete when `text.utf8.count >= len`. When it
is shorter, the phone fetches the full text over Wi-Fi (see below).

### Write semantics

tetherd calls `WriteValue` with `type = request`. BlueZ sends an ATT Write
Request when the value fits the MTU and a prepare/execute long write when it
does not. The phone receives a long write as one `didReceiveWrite` batch of
offset chunks and reassembles them by offset before decoding.

### Fetching the rest over Wi-Fi

When `text` is an excerpt, the app opens a one-shot mTLS connection to the
last known daemon (the same path the Shortcuts intents use), sends
`clipboard_get`, and takes the `clipboard_content` reply as the full text when
its length reaches `len`. This runs inside a `beginBackgroundTask` window;
iOS grants a few seconds after a Bluetooth wake, enough for one round trip.
If the fetch fails, the notification carries the excerpt and its title says so.

## Daemon behaviour (`src/core/src/bluetooth/clipboard_gatt.cpp`)

`ClipboardGattClient` owns one writer thread and a single pending slot.

1. `update(text)` runs on the network loop for every Wayland clipboard change
   (the same callback that broadcasts `clipboard_updated` over Wi-Fi) and for
   a `clipboard_set` from a local client (the CLI). It bumps `seq`, encodes
   the value, stores it as the pending value, and wakes the writer. A newer
   value replaces an older pending one. `update(text, false)` bumps `seq` and
   writes nothing: used for `clipboard_set` from the phone itself.
   The writer sends only after the clipboard has been quiet for 2 seconds, so
   a burst of copies becomes one write and one notification. The Wi-Fi
   broadcast is not delayed.
2. The writer finds the phone: the device whose address matches the
   supervised address in the Bluetooth config, else any device with an Apple
   modalias whose LE bearer is connected.
3. It looks the characteristic up once per phone through
   `GetManagedObjects`, matching `org.bluez.GattCharacteristic1` objects under
   the phone's device path by UUID, and caches the path.
4. It writes. On `UnknownObject` or `UnknownMethod` (the phone republished
   its services and the path moved) it looks the path up again and retries
   once.

Log lines, in `$XDG_STATE_HOME/tether/tetherd.log`:

| Line | Meaning |
|---|---|
| `clipboard sent to the phone (N bytes)` | the write was acknowledged |
| `clipboard not sent, no phone on Bluetooth` | no supervised or LE-connected Apple device |
| `clipboard not sent, the phone does not serve the clipboard characteristic (…)` | the app is not running, the toggle is off, or BlueZ has not re-enumerated yet |
| `clipboard write failed: …` | BlueZ refused the write; the text is the D-Bus error |

The Wayland cache compare in `WaylandContext` stops the echo: text the phone
sent over Wi-Fi primes the cache before the compositor reports it, so the
change callback stays silent for it.

## App behaviour (`apple/Tether/Bluetooth/`)

### `DesktopClipboardMonitor`

- Creates a `CBPeripheralManager` on the main queue with restore identifier
  `net.jeedup.Tether.desktop-clipboard` and `ShowPowerAlert` off.
- On `.poweredOn`, adds the service with the one write characteristic. On
  `willRestoreState`, adopts the restored service instead of adding it again.
- On `didReceiveWrite`, reassembles the chunks, responds `.success`, decodes
  the JSON, applies the `seq` guard (last applied `seq` lives in
  `UserDefaults`), and either delivers the complete text or starts the Wi-Fi
  fetch.
- Keeps a 40-line trace (`trace`) of every step with timestamps. Settings
  shows it under the Bluetooth status as **Log**. This exists because iOS 27's
  syslog relay (`idevicesyslog`) does not show an app's `os_log` lines, so the
  screen is the only place a user can read them.
- The enabled flag is `TetherBluetoothClipboardEnabled` in `UserDefaults`.

### `DesktopClipboardService`

Process-wide singleton, created from `AppDelegate` at every launch so a
background relaunch has somewhere to deliver to before any view exists.

- App in front: hands the text to the view model, which writes the
  pasteboard when Automatic Clipboard Sync is on and records it in the
  clipboard history.
- App in the background: posts a local notification, category
  `TETHER_DESKTOP_CLIPBOARD`, title `Copied on <desktop name>` (with
  `(excerpt)` when the Wi-Fi fetch failed), body a one-line preview of up to
  200 characters, the full text in `userInfo`, time-sensitive interruption
  level. One fixed request identifier, so a newer copy replaces the previous
  notification instead of stacking.
- The category has one action, **Copy**, with the `.foreground` option. Both
  Copy and a plain tap open the app. The response handler writes the
  pasteboard itself, holding the text until `didBecomeActive` when the app is
  still coming to the front (iOS drops writes made during the transition). It
  does not go through the view model: after a background relaunch by
  CoreBluetooth no view exists, so the view model is never initialised, and
  a tap has to work in that state.

### View model

- `applyDesktopClipboard(text, explicit:)` is the single entry for desktop
  text from any transport. It dedupes against the last applied remote text so
  a change that arrives over both Wi-Fi and Bluetooth (app in front, both
  connected) is applied once. `explicit` (a notification tap) bypasses the
  dedupe and the Automatic Clipboard Sync setting.
- `bluetoothClipboardEnabled`, `bluetoothClipboardStatus` and
  `bluetoothClipboardTrace` back the Settings section.

### Settings section

**Bluetooth Clipboard** → toggle *Desktop Copies in Background*, a status row
(Off, Bluetooth is off, Not allowed in Settings, Starting, Ready) and the
**Log** disclosure.

### Info.plist

`UIBackgroundModes` = `bluetooth-peripheral`, plus
`NSBluetoothAlwaysUsageDescription`.

## Related: Shortcuts actions

Independent of Bluetooth, the fork adds two App Intents that run with the app
in the background, for the other direction and for a pull:

- **Send to Desktop Clipboard** (text parameter): `clipboard_set` over the
  one-shot mTLS connection. Pair with *Get Clipboard* in a shortcut on the
  Action Button or Back Tap for iPhone → desktop in one gesture.
- **Get Desktop Clipboard** (returns text): `clipboard_get`. Pair with *Copy
  to Clipboard*.

Neither touches `UIPasteboard` itself, since iOS denies it to a backgrounded
app. The shortcut moves the text across that boundary.

### Sync Clipboard

One action for both directions, meant for the Action Button:
`Get Clipboard → Sync Clipboard → Copy to Clipboard`. iOS gives no time for
the phone's clipboard, the desktop reports one for its own (`changed_at` in
`clipboard_content`, milliseconds on the desktop's clock), so the desktop is
the side that can be known to be newer:

1. The desktop clipboard changed since the last sync (its `changed_at` is
   above the one remembered, and its text is not the last synced text) and
   differs from the phone's: **pull**. The desktop text is returned.
2. Otherwise the phone's text differs from the last synced text: **push**
   (`clipboard_set`). The phone text is returned.
3. Otherwise nothing changes.

The result is always the text the phone should hold, so the shortcut ends
with *Copy to Clipboard* unconditionally, and the intent's dialog says which
way it went. The shortcut is built by hand on the phone: iOS imports only
`.shortcut` files signed by Apple's `shortcuts sign`, which runs on macOS
only and needs an iCloud login, so neither Linux nor a CI runner can produce
one, and no API lets an app install a shortcut. When both sides changed since the last sync the desktop wins,
because its change is the one with a known time. State (last synced text,
last desktop `changed_at`) lives in the app's `UserDefaults`.

## Security

- The characteristic requires an encrypted link. Only the bonded desktop can
  write it.
- The value carries the clipboard text in the clear inside the encrypted LE
  link, the same exposure the Wi-Fi path has inside mTLS.
- The desktop writes only to the phone it supervises (or, failing that, an
  LE-connected Apple device), never to an arbitrary peer.
- Nothing is advertised. The feature adds no discoverability to either side.

## Failure modes and diagnostics

| Symptom | Where to look |
|---|---|
| Status stays *Starting* | Log row: `add service failed` means BlueZ or iOS refused the service; Bluetooth permission denied shows as *Not allowed in Settings* |
| tetherd says the phone does not serve the characteristic | the app is not running (force-quit), the toggle is off, or BlueZ still holds the old GATT table. `bluetoothctl` → `gatt.list-attributes <phone>` shows what BlueZ sees |
| Notification arrives, tap does nothing | Log row should show `notification tapped`; if it does, the pasteboard write happened on the next active transition and the Clipboard tab lists the entry |
| No notification, no log line | the write did not reach the app: check tetherd's log, then `sudo btmon -t` filtered on `ATT:` for the Write Request |

Screenshots of the phone from Linux: mount the developer disk image with
`pymobiledevice3 mounter auto-mount`, run
`sudo ~/.local/bin/pymobiledevice3 remote tunneld` in the background, then
`pymobiledevice3 developer dvt screenshot out.png --tunnel ''`.

## Limits and future work

- Text only. Images are not read from the Wayland clipboard and the value has
  no binary field. The intended shape: the write says an image was copied,
  the notification reads *Copied an image*, the tap fetches the PNG over
  Wi-Fi and sets `UIPasteboard.general.image`.
- iPhone → desktop stays one gesture (Action Button / Back Tap → shortcut).
  iOS gives no background clipboard-changed event.
- The tap is the floor for background delivery, see the constraints above.
- Long text needs Wi-Fi for the remainder. A future variant could stream the
  rest over a second characteristic.
