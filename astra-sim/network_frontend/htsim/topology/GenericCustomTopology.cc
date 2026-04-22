#include "GenericCustomTopology.hh"

#include "config.h"
#include "route.h"
#include "queue.h"
#include "randomqueue.h"
#include "compositequeue.h"
#include "queue_lossless_output.h"
#include "queue_lossless_input.h"
#include "pipe.h"
#include "eventlist.h"
#include "switch.h"

#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <queue>
#include <sstream>
#include <string>
#include <vector>

namespace HTSim {

// Queue sizing: 1 MB per port by default, comfortably >= BDP for links up to
// 400 Gbps × 20 us of round-trip delay in a data-center ring.  Overridable
// via ASTRASIM_HTSIM_QUEUE_BYTES env var.  Earlier FatTree default (12 KB)
// caused severe loss on multi-hop ring paths.
static mem_b queue_size_bytes_default() {
    const char* env = std::getenv("ASTRASIM_HTSIM_QUEUE_BYTES");
    if (env) {
        char* endp = nullptr;
        long v = std::strtol(env, &endp, 10);
        if (endp && endp != env && v > 0) return static_cast<mem_b>(v);
    }
    return 1 * 1024 * 1024;
}
static const mem_b kDefaultQueueBytes = queue_size_bytes_default();
static const mem_b kDropThresholdBytes = kDefaultQueueBytes - (1500 * 8); // leave 12 KB headroom

// §11.5 / U8 — GatewayQueue per-region. Cross-region (inter-DC) links face
// deeper BDP + more bursty traffic than intra-DC links, and under OCS
// reconfiguration they also see bursts as paths rewire. Default: 4× the
// normal per-port queue. Overridable via ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES.
static mem_b gateway_queue_size_bytes_default() {
    const char* env = std::getenv("ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES");
    if (env) {
        char* endp = nullptr;
        long v = std::strtol(env, &endp, 10);
        if (endp && endp != env && v > 0) return static_cast<mem_b>(v);
    }
    return 4 * kDefaultQueueBytes;
}
static const mem_b kGatewayQueueBytes = gateway_queue_size_bytes_default();
static const mem_b kGatewayDropThresholdBytes = kGatewayQueueBytes - (1500 * 8);

static GenericCustomTopology::QueueDiscipline parse_queue_disc() {
    const char* env = std::getenv("ASTRASIM_HTSIM_QUEUE_TYPE");
    if (!env) return GenericCustomTopology::QueueDiscipline::Random;
    std::string s(env);
    for (auto& c : s) c = std::tolower(c);
    if (s == "lossless" || s == "lossless_input" || s == "pfc")
        return GenericCustomTopology::QueueDiscipline::Lossless;
    if (s == "composite" || s == "ecn")
        return GenericCustomTopology::QueueDiscipline::Composite;
    return GenericCustomTopology::QueueDiscipline::Random;
}

// PFC thresholds — in bytes.  Defaults scale with the default queue size
// (1 MB): high = 75%, low = 50%.  Override via env.
static uint64_t pfc_threshold_bytes(const char* var, uint64_t default_bytes) {
    const char* env = std::getenv(var);
    if (!env) return default_bytes;
    char* endp = nullptr;
    long v = std::strtol(env, &endp, 10);
    if (endp && endp != env && v > 0) return static_cast<uint64_t>(v) * 1024; // KB -> bytes
    return default_bytes;
}

// U3 DCQCN — ECN marking thresholds for CompositeQueue.  Values in bytes.
// KMIN = start marking probabilistically; KMAX = always mark.  Below KMIN no
// mark.  These are the same knobs as ns-3 `KMIN_MAP`/`KMAX_MAP` (per link bw
// in the full map, but we accept a single global value from env for
// simplicity — the per-bw map is a U3 follow-up when AIMD rate control
// in RoceSrc lands).
struct DcqcnThresholds {
    uint64_t kmin_bytes;
    uint64_t kmax_bytes;
    bool configured;
};
static DcqcnThresholds read_dcqcn_thresholds(mem_b maxsize) {
    DcqcnThresholds t{0, 0, false};
    const char* kmin = std::getenv("ASTRASIM_HTSIM_DCQCN_KMIN_KB");
    const char* kmax = std::getenv("ASTRASIM_HTSIM_DCQCN_KMAX_KB");
    if (kmin) {
        char* ep = nullptr;
        long v = std::strtol(kmin, &ep, 10);
        if (ep && ep != kmin && v > 0) { t.kmin_bytes = static_cast<uint64_t>(v) * 1024; t.configured = true; }
    }
    if (kmax) {
        char* ep = nullptr;
        long v = std::strtol(kmax, &ep, 10);
        if (ep && ep != kmax && v > 0) { t.kmax_bytes = static_cast<uint64_t>(v) * 1024; t.configured = true; }
    }
    if (t.configured) {
        // Apply sensible defaults if only one side provided.
        if (t.kmin_bytes == 0) t.kmin_bytes = maxsize / 10;
        if (t.kmax_bytes == 0) t.kmax_bytes = maxsize - maxsize / 10;
        if (t.kmin_bytes > t.kmax_bytes) {
            std::swap(t.kmin_bytes, t.kmax_bytes);
        }
        // Clamp within [0, maxsize].
        if (t.kmax_bytes > static_cast<uint64_t>(maxsize)) t.kmax_bytes = maxsize;
        if (t.kmin_bytes > t.kmax_bytes) t.kmin_bytes = t.kmax_bytes / 2;
    }
    return t;
}

GenericCustomTopology::GenericCustomTopology(EventList* eventlist,
                                             QueueLoggerFactory* qlf,
                                             Logfile* logfile)
    : _eventlist(eventlist), _qlf(qlf), _logfile(logfile) {
    _queue_disc = parse_queue_disc();
    if (_queue_disc == QueueDiscipline::Lossless) {
        // Set global PFC marking thresholds.  LosslessInputQueue tracks its
        // own contribution to the downstream output queue's backlog, so the
        // threshold caps _per iq_ not per output queue.  For N-way incast to
        // hit the output maxsize (1 MB default), per-iq should be well below
        // 1MB/N.  Default 200 KB copes with up to ~5-way incast before
        // aggregate queue fill crosses the 1MB "LOSSLESS not working"
        // mark.  Override via ASTRASIM_HTSIM_PFC_HIGH_KB / LOW_KB.
        uint64_t hi = pfc_threshold_bytes("ASTRASIM_HTSIM_PFC_HIGH_KB", 200 * 1024);
        uint64_t lo = pfc_threshold_bytes("ASTRASIM_HTSIM_PFC_LOW_KB",  50 * 1024);
        if (lo >= hi) lo = hi / 3;
        LosslessInputQueue::_high_threshold = hi;
        LosslessInputQueue::_low_threshold  = lo;
        std::cout << "[generic] queue_disc=lossless PFC thresholds high="
                  << hi/1024 << "KB low=" << lo/1024 << "KB" << std::endl;
    } else if (_queue_disc == QueueDiscipline::Composite) {
        std::cout << "[generic] queue_disc=composite (CompositeQueue ECN+fair drop)" << std::endl;
        // Best-effort report of DCQCN marking thresholds, if configured.
        auto dt = read_dcqcn_thresholds(kDefaultQueueBytes);
        if (dt.configured) {
            std::cout << "[generic] DCQCN ECN marking kmin=" << (dt.kmin_bytes/1024)
                      << "KB kmax=" << (dt.kmax_bytes/1024)
                      << "KB (full RoCE AIMD rate control deferred — ECN path only)"
                      << std::endl;
        }
    }
}

int GenericCustomTopology::region_of(uint32_t node) const {
    if (node >= _nodes.size()) return 0;
    return _nodes[node].region_id;
}

double GenericCustomTopology::max_host_linkspeed_bps() const {
    double bw = 0.0;
    for (const auto& d : _links) {
        bool src_is_host = (d.src < _num_nodes) && !_nodes[d.src].is_switch;
        bool dst_is_host = (d.dst < _num_nodes) && !_nodes[d.dst].is_switch;
        if (src_is_host || dst_is_host) {
            if (d.bw_bps > bw) bw = d.bw_bps;
        }
    }
    return bw;
}

double GenericCustomTopology::recommended_nic_linkspeed_bps() const {
    // Split links into host-adjacent and backbone (switch-only).
    double max_host_bw = 0.0;
    double min_backbone_bw = 0.0;
    bool has_backbone = false;
    for (const auto& d : _links) {
        bool src_is_host = (d.src < _num_nodes) && !_nodes[d.src].is_switch;
        bool dst_is_host = (d.dst < _num_nodes) && !_nodes[d.dst].is_switch;
        bool is_host_adj = src_is_host || dst_is_host;
        if (is_host_adj) {
            if (d.bw_bps > max_host_bw) max_host_bw = d.bw_bps;
        } else {
            if (!has_backbone || d.bw_bps < min_backbone_bw) {
                min_backbone_bw = d.bw_bps;
                has_backbone = true;
            }
        }
    }
    if (!has_backbone) return max_host_bw;   // No switch↔switch links — single-tier fabric.
    // Pace at the slower of (wire speed, slowest backbone link). This matches
    // fluid-level bottleneck bandwidth for the typical path that crosses the
    // backbone, and it avoids driving htsim at a rate the fabric cannot drain.
    return std::min(max_host_bw, min_backbone_bw);
}

bool GenericCustomTopology::load(const std::string& path) {
    std::ifstream f(path);
    if (!f) {
        std::cerr << "[GenericCustomTopology] Cannot open topology file: " << path << "\n";
        return false;
    }

    std::string first_line;
    if (!std::getline(f, first_line)) {
        std::cerr << "[GenericCustomTopology] Empty topology file\n";
        return false;
    }
    {
        std::istringstream iss(first_line);
        iss >> _num_nodes >> _num_switches >> _num_links_declared;
    }

    std::string second_line;
    if (!std::getline(f, second_line)) {
        std::cerr << "[GenericCustomTopology] Missing switch ID line\n";
        return false;
    }

    _nodes.resize(_num_nodes);
    for (uint32_t i = 0; i < _num_nodes; i++) {
        _nodes[i].id = i;
        _nodes[i].is_switch = false;
        _nodes[i].region_id = 0;
    }

    {
        std::istringstream iss(second_line);
        uint32_t sw;
        while (iss >> sw) {
            if (sw >= _num_nodes) {
                std::cerr << "[GenericCustomTopology] Switch id " << sw
                          << " exceeds num_nodes " << _num_nodes << "\n";
                return false;
            }
            _nodes[sw].is_switch = true;
        }
    }

    _no_of_hosts = _num_nodes - _num_switches;

    std::string line;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        // Trim leading whitespace.
        size_t start = line.find_first_not_of(" \t\r\n");
        if (start == std::string::npos) continue;
        line = line.substr(start);
        if (line.empty() || line[0] == '#') {
            // §11.5 #REGIONS block (Phase 1.5 hook). Syntax:
            //   #REGIONS <num_regions>
            //   <node_id> <region_id> ...
            if (line.rfind("#REGIONS", 0) == 0) {
                std::istringstream iss(line);
                std::string tag;
                iss >> tag >> _num_regions;
                std::string mapping_line;
                if (!std::getline(f, mapping_line)) {
                    std::cerr << "[GenericCustomTopology] #REGIONS missing mapping line\n";
                    return false;
                }
                std::istringstream mss(mapping_line);
                uint32_t nid; int rid;
                while (mss >> nid >> rid) {
                    if (nid < _num_nodes) _nodes[nid].region_id = rid;
                }
            }
            continue;  // regular comment
        }
        if (!parse_link_line(line)) {
            std::cerr << "[GenericCustomTopology] Failed to parse link line: " << line << "\n";
            return false;
        }
    }

    if (_links.size() != _num_links_declared) {
        std::cerr << "[GenericCustomTopology] Warning: declared " << _num_links_declared
                  << " links, parsed " << _links.size() << "\n";
    }

    build_htsim_objects();
    build_routing_table();
    return true;
}

bool GenericCustomTopology::parse_link_line(const std::string& line) {
    std::istringstream iss(line);
    GenLinkDesc d;
    std::string bw_tok, lat_tok, err_tok, extra_tok;
    if (!(iss >> d.src >> d.dst >> bw_tok >> lat_tok >> err_tok)) {
        return false;
    }
    d.bw_bps = parse_bandwidth(bw_tok);
    d.latency_ps = parse_latency(lat_tok);
    try { d.error_rate = std::stod(err_tok); } catch (...) { d.error_rate = 0.0; }
    d.link_type = GenLinkType::Intra;
    // Remaining tokens can be (in any order): a link-type keyword
    // (intra/inter_leaf/inter_spine/wan) and/or an asymmetry suffix of the
    // form `@<rev_bw>/<rev_lat>` (e.g. `@100Gbps/50ms`).
    while (iss >> extra_tok) {
        if (!extra_tok.empty() && extra_tok[0] == '@') {
            std::string spec = extra_tok.substr(1);
            size_t slash = spec.find('/');
            if (slash != std::string::npos) {
                std::string rev_bw_tok = spec.substr(0, slash);
                std::string rev_lat_tok = spec.substr(slash + 1);
                d.bw_rev_bps = parse_bandwidth(rev_bw_tok);
                d.latency_rev_ps = parse_latency(rev_lat_tok);
            }
        } else {
            d.link_type = parse_link_type(extra_tok);
        }
    }
    _links.push_back(d);
    return true;
}

double GenericCustomTopology::parse_bandwidth(const std::string& tok) {
    // Examples: "4800Gbps", "400Gbps", "800Mbps"
    double val = std::atof(tok.c_str());
    if (tok.find("Gbps") != std::string::npos) {
        return val * 1e9;
    } else if (tok.find("Mbps") != std::string::npos) {
        return val * 1e6;
    } else if (tok.find("Kbps") != std::string::npos) {
        return val * 1e3;
    }
    return val;  // assume bps
}

uint64_t GenericCustomTopology::parse_latency(const std::string& tok) {
    // Examples: "0.00015ms", "0.5us", "100ns", "0.1s"
    double val = std::atof(tok.c_str());
    if (tok.find("ms") != std::string::npos) {
        return static_cast<uint64_t>(val * 1e9);     // ms → ps
    } else if (tok.find("us") != std::string::npos) {
        return static_cast<uint64_t>(val * 1e6);     // us → ps
    } else if (tok.find("ns") != std::string::npos) {
        return static_cast<uint64_t>(val * 1e3);     // ns → ps
    } else if (tok.find('s') != std::string::npos) {
        return static_cast<uint64_t>(val * 1e12);    // s → ps
    }
    return static_cast<uint64_t>(val);  // assume ps
}

GenLinkType GenericCustomTopology::parse_link_type(const std::string& tok) {
    if (tok == "intra") return GenLinkType::Intra;
    if (tok == "inter_leaf") return GenLinkType::InterLeaf;
    if (tok == "inter_spine") return GenLinkType::InterSpine;
    if (tok == "wan") return GenLinkType::Wan;
    return GenLinkType::Intra;
}

// Allocate a queue per the selected discipline.  `is_host_egress` is
// currently unused but retained for future differentiation (e.g. larger
// buffer on host NICs).  LosslessOutputQueue is used everywhere in lossless
// mode: the patched htsim handles the first-hop case where the packet
// arrives without an ingress VirtualQueue.
static Queue* alloc_output_queue(GenericCustomTopology::QueueDiscipline disc,
                                 linkspeed_bps bw,
                                 mem_b maxsize,
                                 EventList& ev,
                                 QueueLogger* ql,
                                 mem_b drop_thr,
                                 bool /*is_host_egress*/) {
    using QD = GenericCustomTopology::QueueDiscipline;
    switch (disc) {
    case QD::Random:
        return new RandomQueue(bw, maxsize, ev, ql, drop_thr);
    case QD::Composite: {
        auto* cq = new CompositeQueue(bw, maxsize, ev, ql);
        // U3 DCQCN — apply ECN marking thresholds if configured.
        auto dt = read_dcqcn_thresholds(maxsize);
        if (dt.configured) {
            cq->set_ecn_thresholds(static_cast<mem_b>(dt.kmin_bytes),
                                   static_cast<mem_b>(dt.kmax_bytes));
        }
        return cq;
    }
    case QD::Lossless:
        return new LosslessOutputQueue(bw, maxsize, ev, ql);
    }
    return new RandomQueue(bw, maxsize, ev, ql, drop_thr);  // unreachable
}

void GenericCustomTopology::build_htsim_objects() {
    _edges.reserve(_links.size());
    _edge_by_pair.reserve(_links.size() * 2);

    int gateway_count = 0;
    for (const auto& d : _links) {
        auto e = std::make_unique<LinkEdge>();
        e->desc = d;

        QueueLogger* qlogger_fwd = _qlf ? _qlf->createQueueLogger() : nullptr;
        QueueLogger* qlogger_rev = _qlf ? _qlf->createQueueLogger() : nullptr;

        // Safe bounds guard — node ids come from topology.txt; parser already
        // bounds-checked, but be defensive.
        bool src_is_host = (d.src < _nodes.size()) && !_nodes[d.src].is_switch;
        bool dst_is_host = (d.dst < _nodes.size()) && !_nodes[d.dst].is_switch;

        // §11.5 / U8 — detect a "gateway" link: a link whose endpoints are in
        // different regions, or whose author-declared link_type is Wan /
        // InterSpine.  Gateway links get the deeper GatewayQueue buffer.
        bool is_gateway = (d.link_type == GenLinkType::Wan) ||
                          (d.link_type == GenLinkType::InterSpine);
        if (!is_gateway && d.src < _nodes.size() && d.dst < _nodes.size()) {
            if (_nodes[d.src].region_id != _nodes[d.dst].region_id) {
                is_gateway = true;
            }
        }
        mem_b q_maxsize = is_gateway ? kGatewayQueueBytes : kDefaultQueueBytes;
        mem_b q_drop_thr = is_gateway ? kGatewayDropThresholdBytes : kDropThresholdBytes;
        if (is_gateway) gateway_count++;

        // Forward (src → dst): Queue feeds Pipe which feeds node at dst side.
        e->queue_fwd = alloc_output_queue(
            _queue_disc,
            static_cast<linkspeed_bps>(d.bw_bps),
            q_maxsize, *_eventlist, qlogger_fwd, q_drop_thr,
            /*is_host_egress=*/src_is_host);
        e->pipe_fwd = new Pipe(static_cast<simtime_picosec>(d.latency_ps), *_eventlist);
        e->queue_fwd->setNext(e->pipe_fwd);
        e->queue_fwd->setName("q_" + std::to_string(d.src) + "_to_" + std::to_string(d.dst));
        e->pipe_fwd->setName("p_" + std::to_string(d.src) + "_to_" + std::to_string(d.dst));

        // Reverse (dst → src): defaults to fwd unless `@<rev_bw>/<rev_lat>`
        // suffix was parsed (§11.5 / U7 WAN asymmetry).
        double rev_bw = (d.bw_rev_bps > 0) ? d.bw_rev_bps : d.bw_bps;
        uint64_t rev_lat = (d.latency_rev_ps > 0) ? d.latency_rev_ps : d.latency_ps;
        e->queue_rev = alloc_output_queue(
            _queue_disc,
            static_cast<linkspeed_bps>(rev_bw),
            q_maxsize, *_eventlist, qlogger_rev, q_drop_thr,
            /*is_host_egress=*/dst_is_host);
        e->pipe_rev = new Pipe(static_cast<simtime_picosec>(rev_lat), *_eventlist);
        e->queue_rev->setNext(e->pipe_rev);
        e->queue_rev->setName("q_" + std::to_string(d.dst) + "_to_" + std::to_string(d.src));
        e->pipe_rev->setName("p_" + std::to_string(d.dst) + "_to_" + std::to_string(d.src));

        // In Lossless mode, create paired LosslessInputQueue on the downstream
        // side of each direction.  The constructor calls
        // peer->setRemoteEndpoint(this) so PAUSE frames can flow back.
        if (_queue_disc == QueueDiscipline::Lossless) {
            e->input_fwd = new LosslessInputQueue(*_eventlist, e->queue_fwd);
            e->input_rev = new LosslessInputQueue(*_eventlist, e->queue_rev);
            e->input_fwd->setName("iq_" + std::to_string(d.src) + "_to_" + std::to_string(d.dst));
            e->input_rev->setName("iq_" + std::to_string(d.dst) + "_to_" + std::to_string(d.src));
        }

        _edge_by_pair[pair_key(d.src, d.dst)] = e.get();
        _edge_by_pair[pair_key(d.dst, d.src)] = e.get();
        _edges.push_back(std::move(e));
    }
    if (gateway_count > 0) {
        std::cout << "[generic] GatewayQueue: " << gateway_count
                  << " inter-region links at " << (kGatewayQueueBytes / 1024)
                  << " KB buffer (regular=" << (kDefaultQueueBytes / 1024) << " KB)\n";
    }
}

GenericCustomTopology::LinkEdge* GenericCustomTopology::find_edge(uint32_t src, uint32_t dst) {
    auto it = _edge_by_pair.find(pair_key(src, dst));
    return (it == _edge_by_pair.end()) ? nullptr : it->second;
}

void GenericCustomTopology::build_routing_table() {
    // Dijkstra from every source node to produce next-hop table.
    // Edge weight = 1 / bw_Gbps so the shortest path prefers high-bandwidth
    // links; in heterogeneous fabrics (4800 Gbps host NIC + 200 Gbps backbone,
    // e.g. llama/inter_dc layouts) plain BFS would route TP rings across the
    // slow backbone because it only counts hops. Disable with
    // ASTRASIM_HTSIM_ROUTE=bfs to fall back to hop-count BFS for debugging.
    _next_hop.assign(_num_nodes, std::vector<int>(_num_nodes, -1));

    const char* route_mode_env = std::getenv("ASTRASIM_HTSIM_ROUTE");
    const bool use_bfs = (route_mode_env && std::string(route_mode_env) == "bfs");

    // Adjacency list: each entry holds (neighbor, edge-weight).
    // Weight = 1/bw_Gbps so higher bandwidth = shorter. Ties by latency.
    struct Neigh { uint32_t v; double w; };
    std::vector<std::vector<Neigh>> adj(_num_nodes);
    for (const auto& d : _links) {
        // Guard against zero-bw links.
        double w = (d.bw_bps > 0) ? (1.0e9 / d.bw_bps) : 1.0;
        if (use_bfs) w = 1.0;
        adj[d.src].push_back({d.dst, w});
        adj[d.dst].push_back({d.src, w});
    }

    const double kInf = std::numeric_limits<double>::infinity();
    for (uint32_t source = 0; source < _num_nodes; source++) {
        std::vector<int> prev(_num_nodes, -1);
        std::vector<double> dist(_num_nodes, kInf);
        dist[source] = 0.0;
        // Min-heap keyed on distance.
        using Entry = std::pair<double, uint32_t>;
        std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> pq;
        pq.push({0.0, source});
        while (!pq.empty()) {
            auto [du, u] = pq.top();
            pq.pop();
            if (du > dist[u]) continue;  // stale
            for (const auto& n : adj[u]) {
                double nd = du + n.w;
                if (nd < dist[n.v]) {
                    dist[n.v] = nd;
                    prev[n.v] = static_cast<int>(u);
                    pq.push({nd, n.v});
                }
            }
        }
        // Reconstruct next-hop from source.
        for (uint32_t dest = 0; dest < _num_nodes; dest++) {
            if (dest == source) {
                _next_hop[source][dest] = -1;
                continue;
            }
            if (prev[dest] < 0) continue;
            uint32_t cur = dest;
            while (prev[cur] != static_cast<int>(source) && prev[cur] >= 0) {
                cur = prev[cur];
            }
            _next_hop[source][dest] = cur;
        }
    }
}

vector<const Route*>* GenericCustomTopology::get_paths(uint32_t src, uint32_t dst) {
    uint64_t key = pair_key(src, dst);
    auto it = _paths_cache.find(key);
    if (it != _paths_cache.end()) {
        return it->second.get();
    }

    auto paths = std::make_unique<std::vector<const Route*>>();
    if (src >= _num_nodes || dst >= _num_nodes || src == dst) {
        auto raw = paths.get();
        _paths_cache[key] = std::move(paths);
        return raw;
    }

    // Follow next_hop until we arrive at dst, pushing (queue, pipe) pairs onto
    // the route.  The sink (TcpSink/receiver) is appended by the caller
    // (HTSimProtoTcp::schedule_htsim_event).
    Route* route = new Route();
    uint32_t cur = src;
    int iters = 0;
    while (cur != dst) {
        if (iters++ > static_cast<int>(_num_nodes)) {
            std::cerr << "[GenericCustomTopology] Routing loop detected from "
                      << src << " to " << dst << "\n";
            delete route;
            auto raw = paths.get();
            _paths_cache[key] = std::move(paths);
            return raw;
        }
        int next = _next_hop[cur][dst];
        if (next < 0) {
            std::cerr << "[GenericCustomTopology] No route from " << cur << " to " << dst << "\n";
            delete route;
            auto raw = paths.get();
            _paths_cache[key] = std::move(paths);
            return raw;
        }
        LinkEdge* e = find_edge(cur, static_cast<uint32_t>(next));
        if (!e) {
            std::cerr << "[GenericCustomTopology] No edge between "
                      << cur << " and " << next << "\n";
            delete route;
            auto raw = paths.get();
            _paths_cache[key] = std::move(paths);
            return raw;
        }
        // Determine direction
        if (e->desc.src == cur) {
            route->push_back(e->queue_fwd);
            route->push_back(e->pipe_fwd);
            if (e->input_fwd) route->push_back(e->input_fwd);
        } else {
            route->push_back(e->queue_rev);
            route->push_back(e->pipe_rev);
            if (e->input_rev) route->push_back(e->input_rev);
        }
        cur = static_cast<uint32_t>(next);
    }

    paths->push_back(route);
    auto raw = paths.get();
    _paths_cache[key] = std::move(paths);
    return raw;
}

vector<const Route*>* GenericCustomTopology::get_bidir_paths(uint32_t src,
                                                             uint32_t dst,
                                                             bool reverse) {
    (void)reverse;
    return get_paths(src, dst);
}

vector<uint32_t>* GenericCustomTopology::get_neighbours(uint32_t src) {
    auto* out = new std::vector<uint32_t>();
    if (src < _num_nodes) {
        for (const auto& d : _links) {
            if (d.src == src) out->push_back(d.dst);
            if (d.dst == src) out->push_back(d.src);
        }
    }
    return out;
}

// OCS mutator — Phase 1 §11.4.  Re-uses htsim EventList.sourceIsPendingRel
// on a tiny EventSource shim.  The real bitrate/delay setters live on
// htsim's BaseQueue / Pipe (setBitrate / setDelay, patched in).
class LinkChangeEvent : public EventSource {
public:
    LinkChangeEvent(EventList& ev,
                    GenericCustomTopology* topo,
                    GenericCustomTopology::LinkEdge* edge,
                    double new_bw_bps,
                    bool up)
        : EventSource(ev, "link_change"),
          _topo(topo), _edge(edge), _new_bw(new_bw_bps), _up(up) {}
    void doNextEvent() override {
        if (!_edge) return;
        // Convert desired bandwidth to htsim's linkspeed_bps (bits per second,
        // integer).  When link is going down we override to 0 — the patched
        // BaseQueue::setBitrate treats that as a logical pause (beginService
        // starves) rather than touching routing tables.
        const double effective_bw = _up ? _new_bw : 0.0;
        auto target_bw = static_cast<linkspeed_bps>(effective_bw);
        if (_edge->queue_fwd) {
            _edge->queue_fwd->setBitrate(target_bw);
        }
        if (_edge->queue_rev) {
            _edge->queue_rev->setBitrate(target_bw);
        }
        // Update desc so subsequent find_edge()->desc.bw_bps readers see the
        // new value (useful for trace / report).
        _edge->desc.bw_bps = effective_bw;

        // P5 (§14.3) — optional route recalc.  Only fires when the user
        // explicitly opts in via ASTRASIM_HTSIM_OCS_REROUTE=1.  Re-runs
        // Dijkstra with the updated bandwidth and clears the path cache so
        // flows starting AFTER this event pick new paths.  Flows already
        // in flight keep their original Route (graveyard preserves it).
        // Require an explicit truthy value so callers can set the var to ""
        // or "0" to disable.  Accept "1", "true", "yes" (case-insensitive).
        static const bool reroute_enabled = []() {
            const char* v = std::getenv("ASTRASIM_HTSIM_OCS_REROUTE");
            if (!v || !*v) return false;
            if (v[0] == '0' && v[1] == 0) return false;
            return true;
        }();
        if (_topo && reroute_enabled) {
            _topo->apply_link_change_reroute(_edge->desc.src, _edge->desc.dst,
                                             effective_bw);
        }

        static const bool verbose = (std::getenv("ASTRASIM_HTSIM_VERBOSE") != nullptr);
        if (verbose) {
            std::cout << "[ocs] t=" << (eventlist().now() / 1000000.0) << "us applied link_change "
                      << _edge->desc.src << "<->" << _edge->desc.dst
                      << " new_bw_bps=" << target_bw
                      << " up=" << _up
                      << " reroute=" << (reroute_enabled ? "1" : "0")
                      << std::endl;
        }
    }
private:
    GenericCustomTopology* _topo;
    GenericCustomTopology::LinkEdge* _edge;
    double _new_bw;
    bool _up;
};

void GenericCustomTopology::schedule_link_change(uint64_t at_ps,
                                                 uint32_t src,
                                                 uint32_t dst,
                                                 double new_bw_bps,
                                                 bool up) {
    LinkEdge* e = find_edge(src, dst);
    if (!e) {
        std::cerr << "[GenericCustomTopology::schedule_link_change] Unknown link "
                  << src << "->" << dst << "\n";
        return;
    }
    auto* ev = new LinkChangeEvent(*_eventlist, this, e, new_bw_bps, up);
    _eventlist->sourceIsPending(*ev, static_cast<simtime_picosec>(at_ps));
}

void GenericCustomTopology::apply_link_change_reroute(uint32_t src,
                                                      uint32_t dst,
                                                      double new_bw_bps) {
    // Update both directions of the link in _links so the next Dijkstra run
    // picks up the new weight.  Links are undirected in _links (we only
    // store one entry per physical link).
    for (auto& d : _links) {
        if ((d.src == src && d.dst == dst) ||
            (d.src == dst && d.dst == src)) {
            d.bw_bps = new_bw_bps;
        }
    }

    // Retire existing cache entries into the graveyard.  We cannot simply
    // clear them because htsim flows started before this event may still
    // reference Route* we handed out earlier; freeing the vector would free
    // the Routes and cause dangling pointers.
    for (auto& kv : _paths_cache) {
        _paths_graveyard.push_back(std::move(kv.second));
    }
    _paths_cache.clear();

    // Recompute next_hop with the updated link weights.  New flows will
    // build fresh Routes lazily through get_paths() / get_bidir_paths().
    build_routing_table();
}

}  // namespace HTSim
