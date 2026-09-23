#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace tether::bluetooth {

    class BluezMonitor;

    // The clipboard characteristic the iPhone app serves over GATT. This machine
    // writes each desktop clipboard change into it, over the LE link that
    // notification mirroring already keeps up. iOS wakes the app for the write
    // even when it is in the background or was terminated, which the Wi-Fi
    // socket cannot do: iOS closes that the moment the app leaves the foreground.
    // The roles mirror ANCS: the phone is the central and the GATT server, this
    // machine is the GATT client.
    inline constexpr const char* UUID_CLIPBOARD_SERVICE = "467df1f1-c20a-448e-ba52-4c46bf02c66b";
    inline constexpr const char* UUID_CLIPBOARD_CHARACTERISTIC = "a643d06f-b1d0-40c0-8d71-a752b08e0abc";

    // Largest attribute value the ATT spec allows.
    inline constexpr size_t CLIPBOARD_GATT_VALUE_MAX = 512;

    struct ClipboardGattState;

    // Writes {"seq":N,"len":L,"text":"..."} to the phone's clipboard
    // characteristic. `text` is cut to fit the attribute; when `len` exceeds it
    // the phone fetches the rest over Wi-Fi.
    class ClipboardGattClient {
    public:
        explicit ClipboardGattClient(BluezMonitor& monitor);
        ~ClipboardGattClient();

        ClipboardGattClient(const ClipboardGattClient&) = delete;
        ClipboardGattClient& operator=(const ClipboardGattClient&) = delete;

        // Publishes a new clipboard value. Returns at once; the write happens
        // on its own thread. `push` false only advances the sequence, for text
        // the phone itself just set.
        void update(const std::string& text, bool push = true);

        // Whether the last write reached the phone.
        bool delivered() const;

    private:
        std::unique_ptr<ClipboardGattState> state_;
    };

    extern ClipboardGattClient* g_clipboard_gatt;

} // namespace tether::bluetooth
