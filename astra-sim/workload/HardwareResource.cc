/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

// TODO: HardwareResource.cc should be moved to the system layer.

#include "astra-sim/workload/HardwareResource.hh"

using namespace std;
using namespace AstraSim;
using namespace Chakra;

typedef ChakraProtoMsg::NodeType ChakraNodeType;

HardwareResource::HardwareResource(uint32_t max_in_flight_cpu_ops,
                                   uint32_t max_in_flight_gpu_comp_ops,
                                   uint32_t max_in_flight_gpu_comm_ops,
                                   uint32_t max_in_flight_gpu_recv_ops,
                                   int sys_id)
    : max_in_flight_cpu_ops(max_in_flight_cpu_ops),
      max_in_flight_gpu_comp_ops(max_in_flight_gpu_comp_ops),
      max_in_flight_gpu_comm_ops(max_in_flight_gpu_comm_ops),
      max_in_flight_gpu_recv_ops(max_in_flight_gpu_recv_ops),
      num_in_flight_cpu_ops(0),
      num_in_flight_gpu_comm_ops(0),
      num_in_flight_gpu_comp_ops(0),
      num_in_flight_gpu_recv_ops(0),
      sys_id(sys_id) {

    num_cpu_ops = 0;
    num_gpu_ops = 0;
    num_gpu_comms = 0;
    num_gpu_recvs = 0;

    tics_cpu_ops = 0;
    tics_gpu_ops = 0;
    tics_gpu_comms = 0;

    // cpu_ops_node = NULL;
    // gpu_ops_node = NULL;
    // gpu_comms_node = NULL;
}

void HardwareResource::occupy(
    const shared_ptr<Chakra::FeederV3::ETFeederNode> node) {
    if (node->is_cpu_op()) {
        assert(num_in_flight_cpu_ops < max_in_flight_cpu_ops);
        ++num_in_flight_cpu_ops;
        ++num_cpu_ops;
        cpu_ops_node.emplace(node->id());
    } else {
        if (node->type() == ChakraNodeType::COMP_NODE) {
            assert(num_in_flight_gpu_comp_ops < max_in_flight_gpu_comp_ops);
            ++num_in_flight_gpu_comp_ops;
            ++num_gpu_ops;
            gpu_ops_node.emplace(node->id());
        } else {
            if (node->type() == ChakraNodeType::COMM_RECV_NODE) {
                assert(num_in_flight_gpu_recv_ops < max_in_flight_gpu_recv_ops);
                ++num_in_flight_gpu_recv_ops;
                ++num_gpu_recvs;
                gpu_recvs_node.emplace(node->id());
                return;
            }
            assert(num_in_flight_gpu_comm_ops < max_in_flight_gpu_comm_ops);
            ++num_in_flight_gpu_comm_ops;
            ++num_gpu_comms;
            gpu_comms_node.emplace(node->id());
        }
    }
}

void HardwareResource::release(
    const shared_ptr<Chakra::FeederV3::ETFeederNode> node) {
    if (node->is_cpu_op()) {
        --num_in_flight_cpu_ops;
        assert(num_in_flight_cpu_ops <= max_in_flight_cpu_ops);
        this->cpu_ops_node.erase(node->id());
    } else {
        if (node->type() == ChakraNodeType::COMP_NODE) {
            --num_in_flight_gpu_comp_ops;
            assert(num_in_flight_gpu_comp_ops <= max_in_flight_gpu_comp_ops);
            this->gpu_ops_node.erase(node->id());
        } else {
            if (node->type() == ChakraNodeType::COMM_RECV_NODE) {
                --num_in_flight_gpu_recv_ops;
                assert(num_in_flight_gpu_recv_ops <=
                       max_in_flight_gpu_recv_ops);
                this->gpu_recvs_node.erase(node->id());
                return;
            }
            --num_in_flight_gpu_comm_ops;
            assert(num_in_flight_gpu_comm_ops <= max_in_flight_gpu_comm_ops);
            this->gpu_comms_node.erase(node->id());
        }
    }
}

bool HardwareResource::is_available(
    const shared_ptr<Chakra::FeederV3::ETFeederNode> node) const {
    if (node->is_cpu_op()) {
        return num_in_flight_cpu_ops < max_in_flight_cpu_ops;
    } else {
        if (node->type() == ChakraNodeType::COMP_NODE) {
            return num_in_flight_gpu_comp_ops < max_in_flight_gpu_comp_ops;
        } else {
            if (node->type() == ChakraNodeType::COMM_RECV_NODE) {
                return num_in_flight_gpu_recv_ops < max_in_flight_gpu_recv_ops;
            }
            return num_in_flight_gpu_comm_ops < max_in_flight_gpu_comm_ops;
        }
    }
}

void HardwareResource::report() {
    cout << "num_cpu_ops: " << num_cpu_ops << endl;
    cout << "num_gpu_ops: " << num_gpu_ops << endl;
    cout << "num_gpu_comms: " << num_gpu_comms << endl;
    cout << "num_gpu_recvs: " << num_gpu_recvs << endl;

    cout << "tics_cpu_ops: " << tics_cpu_ops << endl;
    cout << "tics_gpu_ops: " << tics_gpu_ops << endl;
    cout << "tics_gpu_comms: " << tics_gpu_comms << endl;
}
