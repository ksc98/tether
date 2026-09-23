#include "tether/bluetooth/clipboard_gatt.hpp"
#include "tether/bluetooth/config.hpp"
#include "tether/bluetooth/monitor.hpp"
#include "tether/bluetooth/objects.hpp"
#include "tether/log.hpp"

#include <atomic>
#include <condition_variable>
#include <gio/gio.h>
#include <mutex>
#include <nlohmann/json.hpp>
#include <thread>
#include <vector>

namespace tether::bluetooth {

    ClipboardGattClient* g_clipboard_gatt = nullptr;

    struct ClipboardGattState {
        BluezMonitor* monitor = nullptr;

        // The writer thread takes the newest pending value; older ones are dropped.
        std::mutex mutex;
        std::condition_variable wake;
        std::vector<guint8> pending;
        bool has_pending = false;
        bool stopping = false;
        uint64_t seq = 0;

        // Characteristic path on the phone, kept until a write says it is gone.
        std::string char_path;
        std::atomic<bool> delivered{false};

        std::thread writer;
    };

    namespace {

        constexpr const char* BLUEZ_NAME = "org.bluez";
        constexpr const char* OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager";
        constexpr const char* IFACE_CHARACTERISTIC = "org.bluez.GattCharacteristic1";
        constexpr int CALL_TIMEOUT_MS = 10000;

        // Cuts `text` so it ends on a UTF-8 character boundary at or before `limit` bytes.
        std::string cut_utf8(const std::string& text, size_t limit) {
            if (text.size() <= limit)
                return text;
            size_t cut = limit;
            while (cut > 0 && (static_cast<unsigned char>(text[cut]) & 0xC0) == 0x80)
                --cut;
            return text.substr(0, cut);
        }

        std::vector<guint8> encode_value(uint64_t seq, const std::string& text) {
            const auto dump = [&](const std::string& part) {
                nlohmann::json j;
                j["seq"] = seq;
                j["len"] = text.size();
                j["text"] = part;
                return j.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
            };

            std::string part = cut_utf8(text, CLIPBOARD_GATT_VALUE_MAX);
            std::string encoded = dump(part);
            // JSON escaping grows the text, so trim by the overshoot until it fits.
            while (encoded.size() > CLIPBOARD_GATT_VALUE_MAX && !part.empty()) {
                const size_t excess = encoded.size() - CLIPBOARD_GATT_VALUE_MAX;
                part = cut_utf8(part, part.size() > excess ? part.size() - excess : 0);
                encoded = dump(part);
            }
            return std::vector<guint8>(encoded.begin(), encoded.end());
        }

        // The phone the daemon supervises, or failing that any Apple device with
        // its LE bearer up.
        std::string phone_device_path(BluezMonitor& monitor) {
            const auto objects = monitor.snapshot();
            const std::string wanted = supervised_address(load_config());
            const Device* fallback = nullptr;
            for (const auto& device : objects.devices) {
                if (!wanted.empty() && device.address == wanted)
                    return device.path;
                if (!fallback && device.le_connected && device.modalias.rfind(MODALIAS_APPLE, 0) == 0)
                    fallback = &device;
            }
            return fallback ? fallback->path : std::string{};
        }

        // Finds the clipboard characteristic under the phone's device path.
        std::string find_characteristic(GDBusConnection* conn, const std::string& device_path) {
            GError* error = nullptr;
            GVariant* reply = g_dbus_connection_call_sync(conn,
                                                          BLUEZ_NAME,
                                                          "/",
                                                          OBJECT_MANAGER,
                                                          "GetManagedObjects",
                                                          nullptr,
                                                          G_VARIANT_TYPE("(a{oa{sa{sv}}})"),
                                                          G_DBUS_CALL_FLAGS_NONE,
                                                          CALL_TIMEOUT_MS,
                                                          nullptr,
                                                          &error);
            if (!reply) {
                g_clear_error(&error);
                return {};
            }

            std::string found;
            GVariant* objects = g_variant_get_child_value(reply, 0);
            GVariantIter iter;
            g_variant_iter_init(&iter, objects);
            const gchar* object_path = nullptr;
            GVariant* interfaces = nullptr;
            while (found.empty() && g_variant_iter_loop(&iter, "{&o@a{sa{sv}}}", &object_path, &interfaces)) {
                if (std::string(object_path).rfind(device_path + "/", 0) != 0)
                    continue;
                GVariant* props = g_variant_lookup_value(interfaces, IFACE_CHARACTERISTIC, G_VARIANT_TYPE("a{sv}"));
                if (!props)
                    continue;
                GVariant* uuid_value = g_variant_lookup_value(props, "UUID", G_VARIANT_TYPE_STRING);
                if (uuid_value) {
                    if (g_strcmp0(g_variant_get_string(uuid_value, nullptr), UUID_CLIPBOARD_CHARACTERISTIC) == 0)
                        found = object_path;
                    g_variant_unref(uuid_value);
                }
                g_variant_unref(props);
            }
            g_variant_unref(objects);
            g_variant_unref(reply);
            return found;
        }

        // Returns the error text, empty on success. `gone` is set when the path
        // no longer exists, which means BlueZ re-enumerated the phone.
        std::string write_value(GDBusConnection* conn,
                                const std::string& path,
                                const std::vector<guint8>& value,
                                bool& gone) {
            GVariantBuilder options;
            g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
            // A request, so the phone acknowledges it and BlueZ uses a long
            // write when the value exceeds the MTU.
            g_variant_builder_add(&options, "{sv}", "type", g_variant_new_string("request"));
            GVariant* bytes = g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, value.data(), value.size(), sizeof(guint8));

            GError* error = nullptr;
            GVariant* reply = g_dbus_connection_call_sync(conn,
                                                          BLUEZ_NAME,
                                                          path.c_str(),
                                                          IFACE_CHARACTERISTIC,
                                                          "WriteValue",
                                                          g_variant_new("(@aya{sv})", bytes, &options),
                                                          nullptr,
                                                          G_DBUS_CALL_FLAGS_NONE,
                                                          CALL_TIMEOUT_MS,
                                                          nullptr,
                                                          &error);
            if (!reply) {
                const std::string message = error && error->message ? error->message : "unknown error";
                gone = message.find("UnknownObject") != std::string::npos ||
                       message.find("UnknownMethod") != std::string::npos;
                g_clear_error(&error);
                return message;
            }
            g_variant_unref(reply);
            return {};
        }

        void writer_loop(ClipboardGattState* state) {
            for (;;) {
                std::vector<guint8> value;
                {
                    std::unique_lock<std::mutex> lock(state->mutex);
                    state->wake.wait(lock, [state] { return state->has_pending || state->stopping; });
                    if (state->stopping)
                        return;
                    value = std::move(state->pending);
                    state->pending.clear();
                    state->has_pending = false;
                }

                GDBusConnection* conn = state->monitor->connection();
                if (!conn)
                    continue;

                const std::string device_path = phone_device_path(*state->monitor);
                if (device_path.empty()) {
                    debug::log(INFO, "bluetooth: clipboard not sent, no phone on Bluetooth");
                    state->delivered = false;
                    continue;
                }

                std::string path;
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    path = state->char_path;
                }
                if (path.empty() || path.rfind(device_path + "/", 0) != 0) {
                    path = find_characteristic(conn, device_path);
                    if (path.empty()) {
                        debug::log(INFO,
                                   "bluetooth: clipboard not sent, the phone does not serve the clipboard "
                                   "characteristic (Tether app closed, or Bluetooth clipboard off)");
                        state->delivered = false;
                        continue;
                    }
                    std::lock_guard<std::mutex> lock(state->mutex);
                    state->char_path = path;
                }

                bool gone = false;
                std::string err = write_value(conn, path, value, gone);
                if (!err.empty() && gone) {
                    // The phone re-published its services; look the path up again.
                    path = find_characteristic(conn, device_path);
                    {
                        std::lock_guard<std::mutex> lock(state->mutex);
                        state->char_path = path;
                    }
                    if (!path.empty())
                        err = write_value(conn, path, value, gone);
                }

                if (err.empty()) {
                    state->delivered = true;
                    debug::log(INFO, "bluetooth: clipboard sent to the phone ({} bytes)", value.size());
                } else {
                    state->delivered = false;
                    debug::log(WARN, "bluetooth: clipboard write failed: {}", err);
                }
            }
        }

    } // namespace

    ClipboardGattClient::ClipboardGattClient(BluezMonitor& monitor) : state_(std::make_unique<ClipboardGattState>()) {
        state_->monitor = &monitor;
        state_->writer = std::thread(writer_loop, state_.get());
    }

    ClipboardGattClient::~ClipboardGattClient() {
        {
            std::lock_guard<std::mutex> lock(state_->mutex);
            state_->stopping = true;
        }
        state_->wake.notify_all();
        if (state_->writer.joinable())
            state_->writer.join();
    }

    bool ClipboardGattClient::delivered() const { return state_->delivered; }

    void ClipboardGattClient::update(const std::string& text, bool push) {
        auto* state = state_.get();
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->seq += 1;
            if (!push)
                return;
            state->pending = encode_value(state->seq, text);
            state->has_pending = true;
        }
        state->wake.notify_one();
    }

} // namespace tether::bluetooth
