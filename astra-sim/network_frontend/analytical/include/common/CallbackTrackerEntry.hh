/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#pragma once

#include <astra-network-analytical/common/Event.h>
#include <astra-network-analytical/common/Type.h>
#include <optional>

using namespace NetworkAnalytical;

namespace AstraSimAnalytical {

/**
 * CallbackTrackerEntry manages sim_send() and sim_recv() callbacks
 * per each unique chunk.
 */
class CallbackTrackerEntry {
  public:
    /**
     * Constructor.
     */
    CallbackTrackerEntry() noexcept;

    /**
     * Register a callback for sim_send() call.
     *
     * @param callback callback function pointer
     * @param arg argument of the callback function
     */
    void register_send_callback(Callback callback, CallbackArg arg) noexcept;

    /**
     * Register a callback for sim_recv() call.
     *
     * @param callback callback function pointer
     * @param arg argument of the callback function
     */
    void register_recv_callback(Callback callback, CallbackArg arg) noexcept;

    /**
     * Check if the transmission of the chunk is finished.
     *
     * @return true if the transmission of the chunk is alread finished,
     *         false otherwise
     */
    [[nodiscard]] bool is_transmission_finished() const noexcept;

    /**
     * Mark the transmission of the chunk as finished.
     */
    void set_transmission_finished() noexcept;

    /**
     * Check the existence of both sim_send() and sim_recv() callbacks.
     *
     * @return true if both sim_send() and sim_recv() callbacks are registered,
     *         false otherwise
     */
    [[nodiscard]] bool both_callbacks_registered() const noexcept;

    /**
     * Invoke the sim_send() callback.
     */
    void invoke_send_handler() noexcept;

    /**
     * Invoke the sim_recv() callback.
     */
    void invoke_recv_handler() noexcept;

    /**
     * Release any registered callbacks without invoking them.
     *
     * @param cleanup_arg cleanup function for callback arguments
     */
    void cleanup_handlers(void (*cleanup_arg)(CallbackArg)) noexcept;

    [[nodiscard]] bool has_send_handler() const noexcept;

    [[nodiscard]] bool has_recv_handler() const noexcept;

    /**
     * Record the event-queue time at which the chunk was handed off to the
     * network backend via sim_send(). Used by the trace/traffic-matrix tooling
     * to aggregate bytes over arbitrary time windows offline.
     */
    void set_send_time(EventTime t) noexcept;

    [[nodiscard]] bool has_send_time() const noexcept;

    [[nodiscard]] EventTime get_send_time() const noexcept;

  private:
    /// sim_send() callback event
    std::optional<Event> send_event;

    /// sim_recv() callback event
    std::optional<Event> recv_event;

    /// true if the transmission of the chunk is already finished, false
    /// otherwise
    bool transmission_finished;

    /// timestamp (ns) at which sim_send() was called for this chunk
    std::optional<EventTime> send_time;
};

}  // namespace AstraSimAnalytical
