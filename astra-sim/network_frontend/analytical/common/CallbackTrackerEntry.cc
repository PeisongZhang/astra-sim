/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "common/CallbackTrackerEntry.hh"
#include <cassert>

using namespace NetworkAnalytical;
using namespace AstraSimAnalytical;

CallbackTrackerEntry::CallbackTrackerEntry() noexcept
    : send_event(std::nullopt),
      recv_event(std::nullopt),
      transmission_finished(false),
      send_time(std::nullopt) {}

void CallbackTrackerEntry::register_send_callback(
    const Callback callback, const CallbackArg arg) noexcept {
    assert(!send_event.has_value());

    // register send callback
    const auto event = Event(callback, arg);
    send_event = event;
}

void CallbackTrackerEntry::register_recv_callback(
    const Callback callback, const CallbackArg arg) noexcept {
    assert(!recv_event.has_value());

    // register recv callback
    const auto event = Event(callback, arg);
    recv_event = event;
}

bool CallbackTrackerEntry::is_transmission_finished() const noexcept {
    return transmission_finished;
}

void CallbackTrackerEntry::set_transmission_finished() noexcept {
    transmission_finished = true;
}

bool CallbackTrackerEntry::both_callbacks_registered() const noexcept {
    // check both callback is registered
    return (send_event.has_value() && recv_event.has_value());
}

void CallbackTrackerEntry::invoke_send_handler() noexcept {
    assert(send_event.has_value());

    // invoke send event
    send_event.value().invoke_event();
    send_event.reset();
}

void CallbackTrackerEntry::invoke_recv_handler() noexcept {
    assert(recv_event.has_value());

    // invoke recv event
    recv_event.value().invoke_event();
    recv_event.reset();
}

void CallbackTrackerEntry::cleanup_handlers(
    void (*cleanup_arg)(CallbackArg)) noexcept {
    assert(cleanup_arg != nullptr);

    if (send_event.has_value()) {
        cleanup_arg(send_event.value().get_handler_arg().second);
        send_event.reset();
    }
    if (recv_event.has_value()) {
        cleanup_arg(recv_event.value().get_handler_arg().second);
        recv_event.reset();
    }
}

bool CallbackTrackerEntry::has_send_handler() const noexcept {
    return send_event.has_value();
}

bool CallbackTrackerEntry::has_recv_handler() const noexcept {
    return recv_event.has_value();
}

void CallbackTrackerEntry::set_send_time(const EventTime t) noexcept {
    send_time = t;
}

bool CallbackTrackerEntry::has_send_time() const noexcept {
    return send_time.has_value();
}

EventTime CallbackTrackerEntry::get_send_time() const noexcept {
    assert(send_time.has_value());
    return send_time.value();
}
