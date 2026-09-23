#include "tether/wayland.hpp"

#include "wayland_protocols/ext-data-control-v1.hpp"
#include "wayland_protocols/wayland.hpp"
#include "wayland_protocols/wlr-data-control-unstable-v1.hpp"

#include <chrono>
#include <cstring>
#include <poll.h>
#include <tether/log.hpp>
#include <wayland-client.h>

namespace tether {

    WaylandContext* g_wayland = nullptr;

    namespace {
        int64_t now_ms() {
            return std::chrono::duration_cast<std::chrono::milliseconds>(
                       std::chrono::system_clock::now().time_since_epoch())
                .count();
        }
    } // namespace

    WaylandContext::WaylandContext(EpollEventLoop& loop) : loop_(loop) {}

    WaylandContext::~WaylandContext() {
        g_wayland = nullptr;
        if (raw_display_) {
            // Crucial: Destroy all regular proxies BEFORE disconnecting the display.
            clipboard_.reset();
            ext_data_control_manager_.reset();
            wlr_data_control_manager_.reset();
            seat_.reset();
            registry_.reset();

            // High-level wrapper for the display itself.
            if (display_) {
                display_.release();
            }

            loop_.removeFd(wl_display_get_fd(raw_display_));
            wl_display_disconnect(raw_display_);
            raw_display_ = nullptr;
        }
    }

    bool WaylandContext::init() {
        raw_display_ = wl_display_connect(nullptr);
        if (!raw_display_) {
            debug::log(ERR, "WaylandContext: Failed to connect to Wayland display");
            return false;
        }

        display_ = std::make_unique<CCWlDisplay>((wl_proxy*)raw_display_);

        auto proxy = display_->sendGetRegistry();
        registry_ = std::make_unique<CCWlRegistry>(proxy);

        registry_->setGlobal([this](CCWlRegistry* r, uint32_t name, const char* interface, uint32_t version) {
            if (std::strcmp(interface, "wl_seat") == 0) {
                auto p = wl_registry_bind((wl_registry*)r->resource(), name, &wl_seat_interface, 1);
                seat_ = std::make_unique<CCWlSeat>((wl_proxy*)p);
            } else if (std::strcmp(interface, "zwlr_data_control_manager_v1") == 0) {
                auto p =
                    wl_registry_bind((wl_registry*)r->resource(), name, &zwlr_data_control_manager_v1_interface, 1);
                wlr_data_control_manager_ = std::make_unique<CCZwlrDataControlManagerV1>((wl_proxy*)p);
            } else if (std::strcmp(interface, "ext_data_control_manager_v1") == 0) {
                auto p = wl_registry_bind((wl_registry*)r->resource(), name, &ext_data_control_manager_v1_interface, 1);
                ext_data_control_manager_ = std::make_unique<CCExtDataControlManagerV1>((wl_proxy*)p);
            }
        });

        // synchronous roundtrips to populate globals and capture initial selection
        wl_display_roundtrip(raw_display_);
        wl_display_roundtrip(raw_display_);
        wl_display_roundtrip(raw_display_);

        if (!seat_) {
            debug::log(ERR, "WaylandContext: compositor exposes no wl_seat.");
            return false;
        }

        // Prefer the standardized protocol; KWin only implements this one.
        if (ext_data_control_manager_) {
            clipboard_ = std::make_unique<DataControlClipboard<CCExtDataControlManagerV1,
                                                               CCExtDataControlDeviceV1,
                                                               CCExtDataControlOfferV1,
                                                               CCExtDataControlSourceV1>>(
                ext_data_control_manager_.get(), (wl_proxy*)seat_->resource(), loop_, raw_display_);
        } else if (wlr_data_control_manager_) {
            clipboard_ = std::make_unique<DataControlClipboard<CCZwlrDataControlManagerV1,
                                                               CCZwlrDataControlDeviceV1,
                                                               CCZwlrDataControlOfferV1,
                                                               CCZwlrDataControlSourceV1>>(
                wlr_data_control_manager_.get(), (wl_proxy*)seat_->resource(), loop_, raw_display_);
        } else {
            debug::log(ERR,
                       "WaylandContext: compositor exposes neither ext_data_control_manager_v1 nor "
                       "zwlr_data_control_manager_v1; clipboard sync unavailable.");
            return false;
        }

        clipboard_->set_update_callback([this](const std::string& data, const std::string& mime) {
            const bool is_image = mime == CLIPBOARD_IMAGE_MIME;
            bool changed = false;
            {
                std::lock_guard<std::mutex> lock(clip_mutex_);
                if (is_image) {
                    changed = cached_clipboard_image_ != data;
                    cached_clipboard_image_ = data;
                } else {
                    changed = cached_clipboard_ != data || !cached_clipboard_image_.empty();
                    cached_clipboard_ = data;
                    cached_clipboard_image_.clear();
                }
            }
            if (!changed)
                return;
            {
                std::lock_guard<std::mutex> lock(clip_mutex_);
                clipboard_changed_at_ms_ = now_ms();
            }
            if (is_image && clipboard_image_cb_) {
                clipboard_image_cb_(data);
            } else if (!is_image && clipboard_cb_) {
                clipboard_cb_(data);
            }
        });

        // Attach to event loop!
        int fd = wl_display_get_fd(raw_display_);
        loop_.addFd(fd, [this](int wfd) {
            struct pollfd pfd{wfd, 0, 0};
            if (poll(&pfd, 1, 0) == 1 && (pfd.revents & (POLLHUP | POLLERR))) {
                debug::log(ERR, "WaylandContext: compositor hung up; exiting for on-demand restart.");
                loop_.stop();
                return;
            }
            if (wl_display_dispatch(raw_display_) < 0) {
                // Display connection is dead
                debug::log(ERR, "WaylandContext: Display connection lost; shutting down for on-demand restart.");
                loop_.stop();
                return;
            }
            wl_display_flush(raw_display_); // flush requests queued during dispatch (offer/source destroys)
        });

        // Flush any pending requests
        wl_display_flush(raw_display_);

        debug::log(INFO, "WaylandContext initialized successfully.");
        return true;
    }

    void WaylandContext::set_clipboard_callback(std::function<void(const std::string&)> cb) {
        clipboard_cb_ = std::move(cb);
    }

    void WaylandContext::set_clipboard_image_callback(std::function<void(const std::string&)> cb) {
        clipboard_image_cb_ = std::move(cb);
    }

    void WaylandContext::copy_to_clipboard(const std::string& text) {
        std::string trimmed = text;
        while (!trimmed.empty() && (trimmed.back() == '\0' || isspace((unsigned char)trimmed.back()))) {
            trimmed.pop_back();
        }

        {
            std::lock_guard<std::mutex> lock(clip_mutex_);
            cached_clipboard_ = trimmed;
            cached_clipboard_image_.clear();
            clipboard_changed_at_ms_ = now_ms();
        }
        if (clipboard_) {
            clipboard_->copy(text);
            wl_display_flush(raw_display_);
        }
    }

    void WaylandContext::copy_image_to_clipboard(const std::string& png) {
        {
            // cached first, so the compositor echoing our own selection is not rebroadcast
            std::lock_guard<std::mutex> lock(clip_mutex_);
            cached_clipboard_image_ = png;
            clipboard_changed_at_ms_ = now_ms();
        }
        if (clipboard_) {
            clipboard_->copy_image(png);
            wl_display_flush(raw_display_);
        }
    }

    std::string WaylandContext::get_clipboard() {
        std::lock_guard<std::mutex> lock(clip_mutex_);
        return cached_clipboard_;
    }

    std::string WaylandContext::get_clipboard_image() {
        std::lock_guard<std::mutex> lock(clip_mutex_);
        return cached_clipboard_image_;
    }

    int64_t WaylandContext::clipboard_changed_at() {
        std::lock_guard<std::mutex> lock(clip_mutex_);
        return clipboard_changed_at_ms_;
    }

} // namespace tether
