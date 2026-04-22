// GenericCustomTopology — reads ASTRA-sim's Custom topology.txt format and
// builds an htsim Pipe/Queue graph with BFS routing + OCS mutator API.
//
// Format (ASTRA-sim Custom topology.txt, compatible with analytical_network
// congestion-aware parser):
//
//   # first line (required):
//   <num_nodes> <num_switches> <num_links>
//   # second line (required): switch node IDs (space separated)
//   <sid_0> <sid_1> ...
//   # remaining lines (one per link; <src> <dst> <bw> <latency> <err>)
//   <src> <dst> 4800Gbps 0.00015ms 0
//
// Phase 1.5 extensions (optional, via #REGIONS block — see §11.5):
//
//   #REGIONS <num_regions>
//   <node_id> <region_id> ...
//   <src> <dst> <bw> <latency> <err> [intra|inter_leaf|inter_spine|wan]
//
// Everything after the mandatory 5 columns is Phase 1.5 metadata; the Phase 1
// parser stores region/link_type into annotations but does not yet change
// routing behaviour based on them.

#pragma once

#include "topology.h"
#include "network.h"
#include "pipe.h"
#include "queue.h"
#include "randomqueue.h"
#include "compositequeue.h"
#include "queue_lossless_output.h"
#include "queue_lossless_input.h"
#include "eventlist.h"
#include "logfile.h"
#include "loggers.h"
#include "switch.h"

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace HTSim {

enum class GenLinkType {
    Intra,          // within a DC
    InterLeaf,      // leaf-spine or leaf-gateway
    InterSpine,     // spine-spine within region
    Wan             // cross-region
};

struct GenLinkDesc {
    uint32_t src;
    uint32_t dst;
    double bw_bps;
    uint64_t latency_ps;
    double error_rate;
    GenLinkType link_type;
    // WAN asymmetry (§11.5 / U7): reverse direction (dst → src) can have a
    // different bandwidth and latency.  Set via the `@<rev_bw>/<rev_lat>`
    // suffix on a link line.  When 0 / 0, reverse uses fwd values.
    double bw_rev_bps = 0.0;
    uint64_t latency_rev_ps = 0;
};

struct GenNodeDesc {
    uint32_t id;
    bool is_switch;
    int region_id;  // 0 if no #REGIONS block present
};

class GenericCustomTopology : public ::Topology {
public:
    GenericCustomTopology(EventList* eventlist,
                          QueueLoggerFactory* qlf,
                          Logfile* logfile);

    // Parse a topology.txt file.  Returns false on parse error.
    bool load(const std::string& path);

    // Maximum bandwidth of any host-attached link (used as the default
    // RoCE NIC pacing rate).  Returns bps.
    double max_host_linkspeed_bps() const;

    // Recommended RoCE NIC pacing rate.  On heterogeneous fabrics (where host
    // NICs are much faster than the backbone) pacing at wire speed pushes the
    // packet-level sim into a retransmission storm with no fluid-level gain.
    // Returns min(max_host_adj, min_backbone_link) — conservative but safe.
    // For homogeneous topologies this equals wire speed.
    double recommended_nic_linkspeed_bps() const;

    // htsim Topology interface.
    vector<const Route*>* get_paths(uint32_t src, uint32_t dst) override;
    vector<const Route*>* get_bidir_paths(uint32_t src, uint32_t dst,
                                          bool reverse) override;
    vector<uint32_t>* get_neighbours(uint32_t src) override;
    uint32_t no_of_nodes() const override { return _nodes.size(); }
    uint32_t no_of_hosts() const { return _no_of_hosts; }

    // OCS mutator API (§11.4). Schedules a bandwidth change (or link up/down)
    // for time `at` (picoseconds).  When `new_bw_bps == 0`, the link is
    // taken down.  Call before starting the simulation.
    void schedule_link_change(uint64_t at_ps,
                              uint32_t src,
                              uint32_t dst,
                              double new_bw_bps,
                              bool up);

    // P5 (§14.3) — route recalc on OCS link change.  Called from
    // LinkChangeEvent::doNextEvent after setBitrate.  Does three things:
    // 1. updates _links[i].bw_bps for the (src,dst) pair so Dijkstra sees
    //    the new weight;
    // 2. rebuilds _next_hop;
    // 3. moves existing _paths_cache entries to _paths_graveyard so any
    //    in-flight Route pointers held by active flows stay alive.
    // Gated by env ASTRASIM_HTSIM_OCS_REROUTE=1 (default: off, preserves
    // legacy behaviour where bw changes only affect queue service rate
    // and not path selection).
    void apply_link_change_reroute(uint32_t src, uint32_t dst, double new_bw_bps);

    // Phase 1.5 accessor — returns region id of a node (0 if no REGIONS block).
    int region_of(uint32_t node) const;

public:
    // Queue discipline used by build_htsim_objects.  Default is `Random`
    // (historical lossy RandomQueue behaviour).  `Lossless` uses
    // LosslessOutputQueue + paired LosslessInputQueue for PFC backpressure
    // (requires PriorityQueue on host-egress for PAUSE support).  `Composite`
    // uses CompositeQueue (ECN + fair drop) — lightweight middle ground.
    enum class QueueDiscipline { Random, Lossless, Composite };

    struct LinkEdge {
        Pipe* pipe_fwd = nullptr;
        Queue* queue_fwd = nullptr;
        Pipe* pipe_rev = nullptr;
        Queue* queue_rev = nullptr;
        // Paired LosslessInputQueue on the downstream side, if any.  In
        // Lossless mode these are inserted into the Route after the pipe
        // so they get visited by sendOn() and can send PAUSE back to the
        // upstream output queue when their queuesize crosses the high
        // threshold.
        LosslessInputQueue* input_fwd = nullptr;
        LosslessInputQueue* input_rev = nullptr;
        GenLinkDesc desc;
    };

    QueueDiscipline queue_discipline() const { return _queue_disc; }

private:
    // Parsing helpers.
    bool parse_header(std::ifstream& f);
    bool parse_switch_line(std::ifstream& f);
    bool parse_link_line(const std::string& line);
    double parse_bandwidth(const std::string& tok);
    uint64_t parse_latency(const std::string& tok);
    GenLinkType parse_link_type(const std::string& tok);

    // Topology construction.
    void build_htsim_objects();
    void build_routing_table();

    // Look up the (Pipe, Queue) pair for a directed link (src, dst).
    LinkEdge* find_edge(uint32_t src, uint32_t dst);

    EventList* _eventlist;
    QueueLoggerFactory* _qlf;
    Logfile* _logfile;

    uint32_t _num_nodes = 0;
    uint32_t _num_switches = 0;
    uint32_t _num_links_declared = 0;
    uint32_t _no_of_hosts = 0;

    QueueDiscipline _queue_disc = QueueDiscipline::Random;

    std::vector<GenNodeDesc> _nodes;
    std::vector<GenLinkDesc> _links;
    int _num_regions = 1;

    // One LinkEdge per undirected link.
    std::vector<std::unique_ptr<LinkEdge>> _edges;
    // Look up edge by (src, dst) — forward direction.
    std::unordered_map<uint64_t, LinkEdge*> _edge_by_pair;

    // Routing: _next_hop[src][dst] = node id to forward to reach dst.
    std::vector<std::vector<int>> _next_hop;

    // Cached routes returned to htsim.  One vector<Route*> per (src, dst).
    std::unordered_map<uint64_t, std::unique_ptr<std::vector<const Route*>>> _paths_cache;

    // P5: Route objects retired by apply_link_change_reroute().  They stay
    // alive here because in-flight flows may still hold Route* pointers we
    // handed out before the reroute.  Never cleared during simulation.
    std::vector<std::unique_ptr<std::vector<const Route*>>> _paths_graveyard;

    static uint64_t pair_key(uint32_t s, uint32_t d) {
        return (uint64_t{s} << 32) | d;
    }
};

}  // namespace HTSim
