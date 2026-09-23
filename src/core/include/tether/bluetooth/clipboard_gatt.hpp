#pragma once

#include <cstdint>
#include <functional>
#include <gio/gio.h>
#include <memory>
#include <string>

namespace tether::bluetooth {

    class BluezMonitor;

    // The clipboard service this machine serves over GATT, so the iPhone app can
    // subscribe from the background and be woken when the desktop clipboard
    // changes. The Wi-Fi connection cannot do that: iOS closes it the moment the
    // app leaves the foreground, but a Bluetooth subscription survives.
    inline constexpr const char* UUID_CLIPBOARD_SERVICE = "467df1f1-c20a-448e-ba52-4c46bf02c66b";
    inline constexpr const char* UUID_CLIPBOARD_CHARACTERISTIC = "a643d06f-b1d0-40c0-8d71-a752b08e0abc";

    // Largest characteristic value the ATT spec allows.
    inline constexpr size_t CLIPBOARD_GATT_VALUE_MAX = 512;

    struct ClipboardGattState;

    // Serves one read+notify characteristic whose value is a JSON document
    // {"seq":N,"len":L,"text":"..."} for the current desktop clipboard. `text`
    // is cut to fit the ATT value size; when `len` exceeds it the phone fetches
    // the rest over Wi-Fi. Reads and notifications require an encrypted link,
    // which the iPhone's bond provides.
    class ClipboardGattServer {
    public:
        explicit ClipboardGattServer(BluezMonitor& monitor);
        ~ClipboardGattServer();

        ClipboardGattServer(const ClipboardGattServer&) = delete;
        ClipboardGattServer& operator=(const ClipboardGattServer&) = delete;

        // Registers the service with the adapter BlueZ currently prefers. Safe
        // to call repeatedly; a no-op while registered. Called from the network
        // loop, never from the monitor thread (BlueZ reads the objects back
        // during RegisterApplication).
        bool ensure_registered();

        // Whether BlueZ currently holds the registration.
        bool registered() const;

        // Publishes a new clipboard value. Called from the network loop; the
        // D-Bus signal goes out on the monitor thread without waiting for it.
        // `notify` false refreshes what a later read returns without waking
        // subscribers, for text a phone itself just set.
        void update(const std::string& text, bool notify = true);

        // Advertises the clipboard service for `seconds` so a phone that has
        // never seen it can find this machine in a scan. Returns false with a
        // reason when BlueZ refuses.
        bool advertise(int seconds, std::string& err);

    private:
        std::unique_ptr<ClipboardGattState> state_;
    };

    extern ClipboardGattServer* g_clipboard_gatt;

} // namespace tether::bluetooth
