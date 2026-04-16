/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "astra-sim/system/BaseStream.hh"

#include "astra-sim/system/StreamBaseline.hh"
#include "astra-sim/system/astraccl/Algorithm.hh"

using namespace AstraSim;

std::map<int, int> BaseStream::synchronizer;
std::map<int, int> BaseStream::synchronizer_target;
std::map<int, int> BaseStream::ready_counter;
std::map<int, std::list<BaseStream*>> BaseStream::suspended_streams;

BaseStream::~BaseStream() {
    auto sync_it = synchronizer.find(stream_id);
    if (sync_it != synchronizer.end()) {
        sync_it->second--;
        if (sync_it->second == 0) {
            synchronizer.erase(sync_it);
            synchronizer_target.erase(stream_id);
            ready_counter.erase(stream_id);
        }
    }

    if (my_current_phase.algorithm != nullptr) {
        delete my_current_phase.algorithm;
        my_current_phase.algorithm = nullptr;
    }

    for (auto& phase : phases_to_go) {
        if (phase.algorithm != nullptr) {
            delete phase.algorithm;
            phase.algorithm = nullptr;
        }
    }
}

void BaseStream::changeState(StreamState state) {
    this->state = state;
}

BaseStream::BaseStream(int stream_id,
                       Sys* owner,
                       std::list<CollectivePhase> phases_to_go,
                       int synchronization_target) {
    this->stream_id = stream_id;
    this->owner = owner;
    this->initialized = false;
    this->phases_to_go = phases_to_go;
    auto sync_target_it = BaseStream::synchronizer_target.find(stream_id);
    if (sync_target_it != BaseStream::synchronizer_target.end()) {
        assert(sync_target_it->second == synchronization_target);
    } else {
        BaseStream::synchronizer_target[stream_id] = synchronization_target;
    }
    if (synchronizer.find(stream_id) != synchronizer.end()) {
        synchronizer[stream_id]++;
    } else {
        synchronizer[stream_id] = 1;
        ready_counter[stream_id] = 0;
    }
    for (auto& vn : phases_to_go) {
        if (vn.algorithm != nullptr) {
            vn.init(this);
        }
    }
    state = StreamState::Created;
    preferred_scheduling = SchedulingPolicy::None;
    creation_time = Sys::boostedTick();
    total_packets_sent = 0;
    current_queue_id = -1;
    priority = 0;
}
