#pragma once

#include <cstdint>
#include <memory>
#include <map>
#include <vector>
#include <ios>
#include <iostream>
#include <fstream>

#include "HTSimSessionImpl.hh"
#include "GenericCustomTopology.hh"

#include "config.h"
#include "clock.h"
#include "loggers.h"
#include "fat_tree_topology.h"
#include "roce.h"

namespace HTSim {

// Phase 1 / §11.8 parallel track: minimal RoCE backend — enough to pass the
// megatron_gpt_76b_1024 acceptance (§11.6) with --htsim-proto roce.  Full
// DCQCN / PFC / HPCC tuning lives in Phase 3 §11.2.
class HTSimProtoRoCE final : public HTSimSession::HTSimSessionImpl {
public:
    HTSimProtoRoCE(const HTSim::tm_info* const tm, int argc, char** argv);
    void run(const HTSim::tm_info* const tm) override;
    void finish() override;
    void schedule_htsim_event(HTSim::FlowInfo flow, int flow_id) override;

private:
    std::unique_ptr<Clock> c;
    linkspeed_bps linkspeed;
    uint32_t no_of_nodes;
    std::stringstream filename;
    std::unique_ptr<Logfile> logfile;
    std::unique_ptr<QueueLoggerFactory> qlf;

    std::unique_ptr<FatTreeTopology> top_fat;
    std::unique_ptr<HTSim::GenericCustomTopology> top_generic;
    ::Topology* active_topology = nullptr;

    // per-(src,dst) path cache
    std::map<std::pair<uint32_t, uint32_t>, std::vector<const Route*>*> net_paths;
};

}  // namespace HTSim
