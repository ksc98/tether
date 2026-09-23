#include "tether/bluetooth/clipboard_gatt.hpp"
#include "tether/bluetooth/monitor.hpp"
#include "tether/bluetooth/objects.hpp"
#include "tether/log.hpp"

#include <mutex>
#include <nlohmann/json.hpp>
#include <vector>

namespace tether::bluetooth {

    ClipboardGattServer* g_clipboard_gatt = nullptr;

    struct ClipboardGattState {
        BluezMonitor* monitor = nullptr;
        GDBusConnection* conn = nullptr;
        std::string adapter_path;

        guint app_id = 0;
        guint service_id = 0;
        guint char_id = 0;
        guint advert_id = 0;
        guint owner_watch_id = 0;

        bool registered = false;
        bool advert_registered = false;
        int advert_timeout = 60;

        // Guards value and seq: update() runs on the network loop, reads on the monitor thread.
        std::mutex mutex;
        std::vector<guint8> value;
        uint64_t seq = 0;
        bool notifying = false;
    };

    namespace {

        constexpr const char* BLUEZ_NAME = "org.bluez";
        constexpr const char* APP_PATH = "/org/tether/clipboard";
        constexpr const char* SERVICE_PATH = "/org/tether/clipboard/service0";
        constexpr const char* CHAR_PATH = "/org/tether/clipboard/service0/char0";
        constexpr const char* ADVERT_PATH = "/org/tether/clipboard_advert";
        constexpr const char* IFACE_OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager";
        constexpr const char* IFACE_GATT_MANAGER = "org.bluez.GattManager1";
        constexpr const char* IFACE_GATT_SERVICE = "org.bluez.GattService1";
        constexpr const char* IFACE_GATT_CHAR = "org.bluez.GattCharacteristic1";
        constexpr const char* IFACE_ADVERT_MANAGER = "org.bluez.LEAdvertisingManager1";
        constexpr const char* IFACE_ADVERT = "org.bluez.LEAdvertisement1";

        constexpr const char* OBJECT_MANAGER_XML = R"XML(
<node>
  <interface name='org.freedesktop.DBus.ObjectManager'>
    <method name='GetManagedObjects'>
      <arg type='a{oa{sa{sv}}}' name='objects' direction='out'/>
    </method>
    <signal name='InterfacesAdded'>
      <arg type='o' name='object'/>
      <arg type='a{sa{sv}}' name='interfaces'/>
    </signal>
    <signal name='InterfacesRemoved'>
      <arg type='o' name='object'/>
      <arg type='as' name='interfaces'/>
    </signal>
  </interface>
</node>)XML";

        constexpr const char* SERVICE_XML = R"XML(
<node>
  <interface name='org.bluez.GattService1'>
    <property name='UUID' type='s' access='read'/>
    <property name='Primary' type='b' access='read'/>
  </interface>
</node>)XML";

        constexpr const char* CHAR_XML = R"XML(
<node>
  <interface name='org.bluez.GattCharacteristic1'>
    <method name='ReadValue'>
      <arg type='a{sv}' name='options' direction='in'/>
      <arg type='ay' name='value' direction='out'/>
    </method>
    <method name='WriteValue'>
      <arg type='ay' name='value' direction='in'/>
      <arg type='a{sv}' name='options' direction='in'/>
    </method>
    <method name='StartNotify'/>
    <method name='StopNotify'/>
    <property name='UUID' type='s' access='read'/>
    <property name='Service' type='o' access='read'/>
    <property name='Flags' type='as' access='read'/>
    <property name='Value' type='ay' access='read'/>
    <property name='Notifying' type='b' access='read'/>
  </interface>
</node>)XML";

        constexpr const char* ADVERT_XML = R"XML(
<node>
  <interface name='org.bluez.LEAdvertisement1'>
    <method name='Release'/>
    <property name='Type' type='s' access='read'/>
    <property name='ServiceUUIDs' type='as' access='read'/>
    <property name='Discoverable' type='b' access='read'/>
    <property name='Timeout' type='q' access='read'/>
    <property name='LocalName' type='s' access='read'/>
  </interface>
</node>)XML";

        GVariant* bytes_variant(const std::vector<guint8>& bytes) {
            return g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, bytes.data(), bytes.size(), sizeof(guint8));
        }

        GVariant* flags_variant() {
            GVariantBuilder builder;
            g_variant_builder_init(&builder, G_VARIANT_TYPE("as"));
            g_variant_builder_add(&builder, "s", "encrypt-read");
            g_variant_builder_add(&builder, "s", "encrypt-notify");
            return g_variant_builder_end(&builder);
        }

        // Adds the service and characteristic property dictionaries, in the
        // shape ObjectManager and the per-object property getters both use.
        void add_service_props(GVariantBuilder* props) {
            g_variant_builder_add(props, "{sv}", "UUID", g_variant_new_string(UUID_CLIPBOARD_SERVICE));
            g_variant_builder_add(props, "{sv}", "Primary", g_variant_new_boolean(TRUE));
        }

        void add_char_props(GVariantBuilder* props, ClipboardGattState* state) {
            g_variant_builder_add(props, "{sv}", "UUID", g_variant_new_string(UUID_CLIPBOARD_CHARACTERISTIC));
            g_variant_builder_add(props, "{sv}", "Service", g_variant_new_object_path(SERVICE_PATH));
            g_variant_builder_add(props, "{sv}", "Flags", flags_variant());
            std::lock_guard<std::mutex> lock(state->mutex);
            g_variant_builder_add(props, "{sv}", "Value", bytes_variant(state->value));
            g_variant_builder_add(props, "{sv}", "Notifying", g_variant_new_boolean(state->notifying));
        }

        void om_method(GDBusConnection*,
                       const gchar*,
                       const gchar*,
                       const gchar*,
                       const gchar* method,
                       GVariant*,
                       GDBusMethodInvocation* invocation,
                       gpointer user_data) {
            auto* state = static_cast<ClipboardGattState*>(user_data);
            if (g_strcmp0(method, "GetManagedObjects") != 0) {
                g_dbus_method_invocation_return_dbus_error(
                    invocation, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
                return;
            }

            GVariantBuilder objects;
            g_variant_builder_init(&objects, G_VARIANT_TYPE("a{oa{sa{sv}}}"));

            {
                GVariantBuilder ifaces;
                g_variant_builder_init(&ifaces, G_VARIANT_TYPE("a{sa{sv}}"));
                GVariantBuilder props;
                g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
                add_service_props(&props);
                g_variant_builder_add(&ifaces, "{sa{sv}}", IFACE_GATT_SERVICE, &props);
                g_variant_builder_add(&objects, "{oa{sa{sv}}}", SERVICE_PATH, &ifaces);
            }
            {
                GVariantBuilder ifaces;
                g_variant_builder_init(&ifaces, G_VARIANT_TYPE("a{sa{sv}}"));
                GVariantBuilder props;
                g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
                add_char_props(&props, state);
                g_variant_builder_add(&ifaces, "{sa{sv}}", IFACE_GATT_CHAR, &props);
                g_variant_builder_add(&objects, "{oa{sa{sv}}}", CHAR_PATH, &ifaces);
            }

            g_dbus_method_invocation_return_value(invocation, g_variant_new("(a{oa{sa{sv}}})", &objects));
        }

        GVariant* service_get_property(
            GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar* name, GError**, gpointer) {
            const std::string prop = name ? name : "";
            if (prop == "UUID")
                return g_variant_new_string(UUID_CLIPBOARD_SERVICE);
            if (prop == "Primary")
                return g_variant_new_boolean(TRUE);
            return nullptr;
        }

        GVariant* char_get_property(GDBusConnection*,
                                    const gchar*,
                                    const gchar*,
                                    const gchar*,
                                    const gchar* name,
                                    GError**,
                                    gpointer user_data) {
            auto* state = static_cast<ClipboardGattState*>(user_data);
            const std::string prop = name ? name : "";
            if (prop == "UUID")
                return g_variant_new_string(UUID_CLIPBOARD_CHARACTERISTIC);
            if (prop == "Service")
                return g_variant_new_object_path(SERVICE_PATH);
            if (prop == "Flags")
                return flags_variant();
            std::lock_guard<std::mutex> lock(state->mutex);
            if (prop == "Value")
                return bytes_variant(state->value);
            if (prop == "Notifying")
                return g_variant_new_boolean(state->notifying);
            return nullptr;
        }

        std::string option_device(GVariant* options) {
            if (!options)
                return {};
            const gchar* device = nullptr;
            if (g_variant_lookup(options, "device", "&o", &device) && device)
                return device;
            return {};
        }

        void char_method(GDBusConnection*,
                         const gchar*,
                         const gchar*,
                         const gchar*,
                         const gchar* method_name,
                         GVariant* parameters,
                         GDBusMethodInvocation* invocation,
                         gpointer user_data) {
            auto* state = static_cast<ClipboardGattState*>(user_data);
            const std::string method = method_name ? method_name : "";

            if (method == "ReadValue") {
                GVariant* options = nullptr;
                g_variant_get(parameters, "(@a{sv})", &options);
                guint16 offset = 0;
                if (options)
                    g_variant_lookup(options, "offset", "q", &offset);
                std::vector<guint8> slice;
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    if (offset < state->value.size())
                        slice.assign(state->value.begin() + offset, state->value.end());
                }
                debug::log(INFO,
                           "bluetooth: clipboard read by {} (offset {}, {} bytes)",
                           option_device(options),
                           offset,
                           slice.size());
                if (options)
                    g_variant_unref(options);
                g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ay)", bytes_variant(slice)));
                return;
            }

            if (method == "StartNotify") {
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    state->notifying = true;
                }
                debug::log(INFO, "bluetooth: clipboard notifications on");
                g_dbus_method_invocation_return_value(invocation, nullptr);
                return;
            }

            if (method == "StopNotify") {
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    state->notifying = false;
                }
                debug::log(INFO, "bluetooth: clipboard notifications off");
                g_dbus_method_invocation_return_value(invocation, nullptr);
                return;
            }

            g_dbus_method_invocation_return_dbus_error(
                invocation, "org.bluez.Error.NotSupported", "the clipboard characteristic is read-only");
        }

        void advert_method(GDBusConnection*,
                           const gchar*,
                           const gchar*,
                           const gchar*,
                           const gchar* method,
                           GVariant*,
                           GDBusMethodInvocation* invocation,
                           gpointer user_data) {
            auto* state = static_cast<ClipboardGattState*>(user_data);
            if (g_strcmp0(method, "Release") == 0) {
                debug::log(INFO, "bluetooth: clipboard advertisement released by BlueZ");
                state->advert_registered = false;
            }
            g_dbus_method_invocation_return_value(invocation, nullptr);
        }

        GVariant* advert_get_property(GDBusConnection*,
                                      const gchar*,
                                      const gchar*,
                                      const gchar*,
                                      const gchar* name,
                                      GError**,
                                      gpointer user_data) {
            auto* state = static_cast<ClipboardGattState*>(user_data);
            const std::string prop = name ? name : "";
            if (prop == "Type")
                return g_variant_new_string("peripheral");
            if (prop == "ServiceUUIDs") {
                GVariantBuilder builder;
                g_variant_builder_init(&builder, G_VARIANT_TYPE("as"));
                g_variant_builder_add(&builder, "s", UUID_CLIPBOARD_SERVICE);
                return g_variant_builder_end(&builder);
            }
            if (prop == "Discoverable")
                return g_variant_new_boolean(TRUE);
            if (prop == "Timeout")
                return g_variant_new_uint16(static_cast<guint16>(state->advert_timeout));
            if (prop == "LocalName")
                return g_variant_new_string("Tether");
            return nullptr;
        }

        const GDBusInterfaceVTable OM_VTABLE = {om_method, nullptr, nullptr, {nullptr}};
        const GDBusInterfaceVTable SERVICE_VTABLE = {nullptr, service_get_property, nullptr, {nullptr}};
        const GDBusInterfaceVTable CHAR_VTABLE = {char_method, char_get_property, nullptr, {nullptr}};
        const GDBusInterfaceVTable ADVERT_VTABLE = {advert_method, advert_get_property, nullptr, {nullptr}};

        guint export_one(GDBusConnection* conn,
                         const char* path,
                         const char* xml,
                         const GDBusInterfaceVTable* vtable,
                         gpointer user_data) {
            GError* error = nullptr;
            GDBusNodeInfo* info = g_dbus_node_info_new_for_xml(xml, &error);
            if (!info) {
                debug::log(ERR, "bluetooth: bad introspection for {}: {}", path, error ? error->message : "unknown");
                g_clear_error(&error);
                return 0;
            }
            guint id = g_dbus_connection_register_object(conn, path, info->interfaces[0], vtable, user_data, nullptr, &error);
            g_dbus_node_info_unref(info);
            if (id == 0) {
                debug::log(ERR, "bluetooth: cannot export {}: {}", path, error ? error->message : "unknown");
                g_clear_error(&error);
            }
            return id;
        }

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

        void on_bluez_owner_changed(GDBusConnection*,
                                    const gchar*,
                                    const gchar*,
                                    const gchar*,
                                    const gchar*,
                                    GVariant* parameters,
                                    gpointer user_data) {
            auto* state = static_cast<ClipboardGattState*>(user_data);
            const gchar* name = nullptr;
            const gchar* old_owner = nullptr;
            const gchar* new_owner = nullptr;
            g_variant_get(parameters, "(&s&s&s)", &name, &old_owner, &new_owner);
            if (g_strcmp0(name, BLUEZ_NAME) != 0)
                return;
            // A restarted bluetoothd has forgotten the registration; the next
            // ensure_registered() redoes it.
            if (state->registered || state->advert_registered)
                debug::log(INFO, "bluetooth: bluetoothd went away; clipboard service needs re-registering");
            state->registered = false;
            state->advert_registered = false;
        }

    } // namespace

    ClipboardGattServer::ClipboardGattServer(BluezMonitor& monitor) : state_(std::make_unique<ClipboardGattState>()) {
        state_->monitor = &monitor;
        state_->conn = monitor.connection();
        {
            std::lock_guard<std::mutex> lock(state_->mutex);
            state_->value = encode_value(0, "");
        }
    }

    ClipboardGattServer::~ClipboardGattServer() {
        auto* state = state_.get();
        if (!state->conn)
            return;

        if (state->registered) {
            GError* error = nullptr;
            GVariant* reply = g_dbus_connection_call_sync(state->conn,
                                                          BLUEZ_NAME,
                                                          state->adapter_path.c_str(),
                                                          IFACE_GATT_MANAGER,
                                                          "UnregisterApplication",
                                                          g_variant_new("(o)", APP_PATH),
                                                          nullptr,
                                                          G_DBUS_CALL_FLAGS_NONE,
                                                          5000,
                                                          nullptr,
                                                          &error);
            if (reply)
                g_variant_unref(reply);
            g_clear_error(&error);
            state->registered = false;
        }
        if (state->advert_registered) {
            GError* error = nullptr;
            GVariant* reply = g_dbus_connection_call_sync(state->conn,
                                                          BLUEZ_NAME,
                                                          state->adapter_path.c_str(),
                                                          IFACE_ADVERT_MANAGER,
                                                          "UnregisterAdvertisement",
                                                          g_variant_new("(o)", ADVERT_PATH),
                                                          nullptr,
                                                          G_DBUS_CALL_FLAGS_NONE,
                                                          5000,
                                                          nullptr,
                                                          &error);
            if (reply)
                g_variant_unref(reply);
            g_clear_error(&error);
            state->advert_registered = false;
        }

        state->monitor->invoke_sync([state] {
            if (state->owner_watch_id) {
                g_dbus_connection_signal_unsubscribe(state->conn, state->owner_watch_id);
                state->owner_watch_id = 0;
            }
            for (guint* id : {&state->char_id, &state->service_id, &state->app_id, &state->advert_id}) {
                if (*id) {
                    g_dbus_connection_unregister_object(state->conn, *id);
                    *id = 0;
                }
            }
        });
    }

    bool ClipboardGattServer::registered() const { return state_->registered; }

    bool ClipboardGattServer::ensure_registered() {
        auto* state = state_.get();
        if (!state->conn)
            return false;
        if (state->registered)
            return true;

        const auto objects = state->monitor->snapshot();
        const Adapter* adapter = preferred_adapter(objects, state->monitor->preferred_adapter_id());
        if (!adapter || !adapter->powered)
            return false;
        state->adapter_path = adapter->path;

        bool exported = false;
        state->monitor->invoke_sync([state, &exported] {
            if (state->app_id == 0)
                state->app_id = export_one(state->conn, APP_PATH, OBJECT_MANAGER_XML, &OM_VTABLE, state);
            if (state->service_id == 0)
                state->service_id = export_one(state->conn, SERVICE_PATH, SERVICE_XML, &SERVICE_VTABLE, state);
            if (state->char_id == 0)
                state->char_id = export_one(state->conn, CHAR_PATH, CHAR_XML, &CHAR_VTABLE, state);
            if (state->owner_watch_id == 0) {
                state->owner_watch_id = g_dbus_connection_signal_subscribe(state->conn,
                                                                           "org.freedesktop.DBus",
                                                                           "org.freedesktop.DBus",
                                                                           "NameOwnerChanged",
                                                                           "/org/freedesktop/DBus",
                                                                           BLUEZ_NAME,
                                                                           G_DBUS_SIGNAL_FLAGS_NONE,
                                                                           on_bluez_owner_changed,
                                                                           state,
                                                                           nullptr);
            }
            exported = state->app_id && state->service_id && state->char_id;
        });
        if (!exported)
            return false;

        // BlueZ calls GetManagedObjects back on the monitor thread before this
        // returns, so the call has to come from another thread.
        GError* error = nullptr;
        GVariantBuilder options;
        g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
        GVariant* reply = g_dbus_connection_call_sync(state->conn,
                                                      BLUEZ_NAME,
                                                      state->adapter_path.c_str(),
                                                      IFACE_GATT_MANAGER,
                                                      "RegisterApplication",
                                                      g_variant_new("(oa{sv})", APP_PATH, &options),
                                                      nullptr,
                                                      G_DBUS_CALL_FLAGS_NONE,
                                                      10000,
                                                      nullptr,
                                                      &error);
        if (!reply) {
            const std::string message = error && error->message ? error->message : "unknown error";
            g_clear_error(&error);
            if (message.find("AlreadyExists") != std::string::npos) {
                state->registered = true;
                debug::log(INFO, "bluetooth: clipboard service was already registered; adopted it");
                return true;
            }
            debug::log(ERR, "bluetooth: RegisterApplication failed: {}", message);
            return false;
        }
        g_variant_unref(reply);
        state->registered = true;
        debug::log(INFO, "bluetooth: clipboard service registered on {}", state->adapter_path);
        return true;
    }

    void ClipboardGattServer::update(const std::string& text) {
        auto* state = state_.get();
        if (!state->conn)
            return;

        bool notify = false;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->seq += 1;
            state->value = encode_value(state->seq, text);
            notify = state->notifying;
        }
        if (!notify || !state->registered)
            return;

        state->monitor->invoke_async([state] {
            GVariantBuilder changed;
            g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                g_variant_builder_add(&changed, "{sv}", "Value", bytes_variant(state->value));
            }
            GVariantBuilder invalidated;
            g_variant_builder_init(&invalidated, G_VARIANT_TYPE("as"));
            GError* error = nullptr;
            g_dbus_connection_emit_signal(state->conn,
                                          nullptr,
                                          CHAR_PATH,
                                          "org.freedesktop.DBus.Properties",
                                          "PropertiesChanged",
                                          g_variant_new("(sa{sv}as)", IFACE_GATT_CHAR, &changed, &invalidated),
                                          &error);
            if (error) {
                debug::log(ERR, "bluetooth: clipboard notify failed: {}", error->message);
                g_clear_error(&error);
            }
        });
    }

    bool ClipboardGattServer::advertise(int seconds, std::string& err) {
        auto* state = state_.get();
        if (!state->conn) {
            err = "Bluetooth is unavailable.";
            return false;
        }
        if (!ensure_registered()) {
            err = "The clipboard service is not registered with BlueZ.";
            return false;
        }
        state->advert_timeout = seconds > 0 ? seconds : 60;

        bool exported = false;
        state->monitor->invoke_sync([state, &exported] {
            if (state->advert_id == 0)
                state->advert_id = export_one(state->conn, ADVERT_PATH, ADVERT_XML, &ADVERT_VTABLE, state);
            exported = state->advert_id != 0;
        });
        if (!exported) {
            err = "Could not prepare the advertisement.";
            return false;
        }

        // Re-registering restarts the timeout, so an active advert goes down first.
        if (state->advert_registered) {
            GError* error = nullptr;
            GVariant* reply = g_dbus_connection_call_sync(state->conn,
                                                          BLUEZ_NAME,
                                                          state->adapter_path.c_str(),
                                                          IFACE_ADVERT_MANAGER,
                                                          "UnregisterAdvertisement",
                                                          g_variant_new("(o)", ADVERT_PATH),
                                                          nullptr,
                                                          G_DBUS_CALL_FLAGS_NONE,
                                                          5000,
                                                          nullptr,
                                                          &error);
            if (reply)
                g_variant_unref(reply);
            g_clear_error(&error);
            state->advert_registered = false;
        }

        GError* error = nullptr;
        GVariantBuilder options;
        g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
        GVariant* reply = g_dbus_connection_call_sync(state->conn,
                                                      BLUEZ_NAME,
                                                      state->adapter_path.c_str(),
                                                      IFACE_ADVERT_MANAGER,
                                                      "RegisterAdvertisement",
                                                      g_variant_new("(oa{sv})", ADVERT_PATH, &options),
                                                      nullptr,
                                                      G_DBUS_CALL_FLAGS_NONE,
                                                      10000,
                                                      nullptr,
                                                      &error);
        if (!reply) {
            err = error && error->message ? error->message : "unknown error";
            g_clear_error(&error);
            debug::log(ERR, "bluetooth: clipboard RegisterAdvertisement failed: {}", err);
            return false;
        }
        g_variant_unref(reply);
        state->advert_registered = true;
        debug::log(INFO, "bluetooth: advertising the clipboard service for {}s", state->advert_timeout);
        return true;
    }

} // namespace tether::bluetooth
