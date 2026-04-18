/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "common/CallbackTracker.hh"
#include <cassert>
#include <sstream>

using namespace AstraSimAnalytical;

CallbackTracker::CallbackTracker() noexcept {
    // initialize tracker
    tracker = {};
}

std::optional<CallbackTrackerEntry*> CallbackTracker::search_entry(
    const int tag,
    const int src,
    const int dest,
    const ChunkSize chunk_size,
    const int chunk_id) noexcept {
    assert(tag >= 0);
    assert(src >= 0);
    assert(dest >= 0);
    assert(chunk_size > 0);
    assert(chunk_id >= 0);

    // create key and search entry
    const auto key = std::make_tuple(tag, src, dest, chunk_size, chunk_id);
    const auto entry = tracker.find(key);

    // no entry exists
    if (entry == tracker.end()) {
        return std::nullopt;
    }

    // return pointer to entry
    return &(entry->second);
}

CallbackTrackerEntry* CallbackTracker::create_new_entry(
    const int tag,
    const int src,
    const int dest,
    const ChunkSize chunk_size,
    const int chunk_id) noexcept {
    assert(tag >= 0);
    assert(src >= 0);
    assert(dest >= 0);
    assert(chunk_size > 0);
    assert(chunk_id >= 0);

    // create key
    const auto key = std::make_tuple(tag, src, dest, chunk_size, chunk_id);

    // create new emtpy entry
    const auto entry = tracker.emplace(key, CallbackTrackerEntry()).first;

    // return pointer to entry
    return &(entry->second);
}

void CallbackTracker::pop_entry(const int tag,
                                const int src,
                                const int dest,
                                const ChunkSize chunk_size,
                                const int chunk_id) noexcept {
    assert(tag >= 0);
    assert(src >= 0);
    assert(dest >= 0);
    assert(chunk_size > 0);
    assert(chunk_id >= 0);

    // create key
    const auto key = std::make_tuple(tag, src, dest, chunk_size, chunk_id);

    // find entry
    const auto entry = tracker.find(key);
    assert(entry != tracker.end());  // entry must exist

    // erase entry from the tracker
    tracker.erase(entry);
}

std::optional<int> CallbackTracker::find_chunk_waiting_for_send(
    const int tag,
    const int src,
    const int dest,
    const ChunkSize chunk_size) noexcept {
    assert(tag >= 0);
    assert(src >= 0);
    assert(dest >= 0);
    assert(chunk_size > 0);

    const auto begin_key = std::make_tuple(tag, src, dest, chunk_size, 0);
    for (auto it = tracker.lower_bound(begin_key); it != tracker.end(); ++it) {
        auto& [key, entry] = *it;
        const auto& [entry_tag, entry_src, entry_dest, entry_chunk_size,
                     entry_chunk_id] = key;
        if (entry_tag != tag || entry_src != src || entry_dest != dest ||
            entry_chunk_size != chunk_size) {
            break;
        }

        if (entry.has_recv_handler() && !entry.has_send_handler() &&
            !entry.is_transmission_finished()) {
            return entry_chunk_id;
        }
    }

    return std::nullopt;
}

std::optional<int> CallbackTracker::find_chunk_waiting_for_recv(
    const int tag,
    const int src,
    const int dest,
    const ChunkSize chunk_size) noexcept {
    assert(tag >= 0);
    assert(src >= 0);
    assert(dest >= 0);
    assert(chunk_size > 0);

    const auto begin_key = std::make_tuple(tag, src, dest, chunk_size, 0);
    for (auto it = tracker.lower_bound(begin_key); it != tracker.end(); ++it) {
        auto& [key, entry] = *it;
        const auto& [entry_tag, entry_src, entry_dest, entry_chunk_size,
                     entry_chunk_id] = key;
        if (entry_tag != tag || entry_src != src || entry_dest != dest ||
            entry_chunk_size != chunk_size) {
            break;
        }

        if (!entry.has_recv_handler() &&
            (entry.has_send_handler() || entry.is_transmission_finished())) {
            return entry_chunk_id;
        }
    }

    return std::nullopt;
}

void CallbackTracker::cleanup_pending_entries(
    void (*cleanup_arg)(CallbackArg)) noexcept {
    assert(cleanup_arg != nullptr);

    for (auto& [key, entry] : tracker) {
        entry.cleanup_handlers(cleanup_arg);
    }
    tracker.clear();
}

std::vector<std::string> CallbackTracker::describe_pending_entries() const
    noexcept {
    std::vector<std::string> descriptions;
    descriptions.reserve(tracker.size());

    for (const auto& [key, entry] : tracker) {
        const auto& [tag, src, dest, chunk_size, chunk_id] = key;
        std::ostringstream oss;
        oss << "tag=" << tag << " src=" << src << " dst=" << dest
            << " size=" << chunk_size << " chunk_id=" << chunk_id
            << " send=" << entry.has_send_handler()
            << " recv=" << entry.has_recv_handler()
            << " finished=" << entry.is_transmission_finished();
        descriptions.push_back(oss.str());
    }

    return descriptions;
}
