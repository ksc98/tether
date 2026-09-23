#pragma once

#include "tether/clipboard.hpp"
#include "tether/event_loop.hpp"
#include <functional>
#include <memory>
#include <mutex>
#include <string>

class CCWlDisplay;
class CCWlRegistry;
class CCWlSeat;
class CCZwlrDataControlManagerV1;
class CCExtDataControlManagerV1;
struct wl_display;

namespace tether {

    class WaylandContext {
    public:
        WaylandContext(EpollEventLoop& loop);
        ~WaylandContext();

        bool init();

        bool clipboard_available() const { return clipboard_ != nullptr; }
        void set_clipboard_callback(std::function<void(const std::string&)> cb);
        void set_clipboard_image_callback(std::function<void(const std::string&)> cb);
        void copy_to_clipboard(const std::string& text);
        void copy_image_to_clipboard(const std::string& png);
        std::string get_clipboard();
        std::string get_clipboard_image();
        // When the clipboard last changed, in milliseconds since the epoch. 0 until it has.
        int64_t clipboard_changed_at();

    private:
        std::mutex clip_mutex_;
        std::string cached_clipboard_;
        std::string cached_clipboard_image_;
        int64_t clipboard_changed_at_ms_ = 0;
        EpollEventLoop& loop_;
        wl_display* raw_display_ = nullptr;
        std::unique_ptr<CCWlDisplay> display_;
        std::unique_ptr<CCWlRegistry> registry_;

        std::unique_ptr<CCWlSeat> seat_;
        std::unique_ptr<CCZwlrDataControlManagerV1> wlr_data_control_manager_;
        std::unique_ptr<CCExtDataControlManagerV1> ext_data_control_manager_;
        std::unique_ptr<ClipboardManager> clipboard_;

        std::function<void(const std::string&)> clipboard_cb_;
        std::function<void(const std::string&)> clipboard_image_cb_;
    };

    extern WaylandContext* g_wayland;

} // namespace tether
