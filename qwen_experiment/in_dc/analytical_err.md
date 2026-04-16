# Analytical Backend Error Analysis

## Scope

Target script:

- `qwen_experiment/in_dc/run_analytical.sh`

Target binary:

- `build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware`

## Observed Symptoms

During execution of `run_analytical.sh`, the analytical congestion-aware backend
showed three distinct problems:

1. The run appeared to "leak memory" because a large number of pending receive
   callbacks accumulated and were only released at process exit.
2. AddressSanitizer reported a real `heap-use-after-free` during analytical
   callback cleanup.
3. Even after the crash was fixed, the simulation still exited with many
   pending callbacks and some unreleased communication resources.

## What Was Actually Happening

The original problem was not a simple shell-script issue. The script only
builds the analytical backend and launches it with:

- `workload/workload`
- `workload/workload.json`
- `astra_system.json`
- `no_memory_expansion.json`
- `analytical_network.yml`

The real issues were inside ASTRA-sim's workload resource model and analytical
network callback cleanup path.

## Root Cause 1: Hardware Resource Model Was Too Rigid

In `astra-sim/workload/Workload.cc`, the workload layer created hardware
resources like this:

```cpp
this->hw_resource = new HardwareResource(1, sys->id);
```

That effectively hardcoded the execution model to a single slot and ignored the
actual communication pattern of the trace.

At the same time, in `astra-sim/workload/HardwareResource.cc`:

- CPU ops were limited to one in flight.
- GPU compute ops were limited to one in flight.
- GPU communication ops were limited to one in flight.
- `COMM_RECV_NODE` was treated as always available and did not consume tracked
  hardware resources at all.

This combination produced a bad failure mode:

- send-side communication was strongly serialized;
- recv-side nodes could be issued without bound;
- pending recv callbacks kept accumulating in the analytical backend;
- memory usage looked like a leak, but the deeper issue was unbounded callback
  buildup caused by an incomplete hardware resource model.

## Root Cause 2: Cleanup Had a Real Use-After-Free

The analytical backend also had a genuine memory bug.

In `network_frontend/analytical/common/CallbackTrackerEntry.cc`, send/recv
callbacks were invoked but not cleared from the tracker entry. Later, cleanup
walked the remaining tracker entries and attempted to free callback arguments
again.

That produced an AddressSanitizer error:

```text
ERROR: AddressSanitizer: heap-use-after-free
... CommonNetworkApi.cc:47 in cleanup_callback_arg
```

So there were two separate layers of failure:

1. resource-model-induced callback accumulation;
2. cleanup path double-free / use-after-free.

## Implemented Fixes

### 1. Made hardware resource capacity configurable

Updated `astra-sim/system/Sys.cc` and `astra-sim/system/Sys.hh` so the system
configuration can now define:

```json
"hardware-resource-capacity": {
  "cpu": 1,
  "gpu-comp": 1,
  "gpu-comm": 1,
  "gpu-recv": 64
}
```

Default behavior remains conservative:

- `cpu = 1`
- `gpu-comp = 1`
- `gpu-comm = 1`
- `gpu-recv = unlimited`

### 2. Passed those limits into the workload layer

Updated `astra-sim/workload/Workload.cc` so `HardwareResource` is constructed
from `Sys` configuration instead of a hardcoded `1`.

### 3. Added explicit recv resource tracking

Updated `astra-sim/workload/HardwareResource.hh` and
`astra-sim/workload/HardwareResource.cc` to track:

- CPU ops
- GPU compute ops
- GPU communication ops
- GPU recv ops

`COMM_RECV_NODE` now has its own in-flight accounting instead of being treated
as unbounded.

### 4. Extended workload completion condition

Updated the workload completion check so the simulation does not report the
workload finished while `gpu-recv` resources are still in flight.

### 5. Fixed callback use-after-free

Updated `network_frontend/analytical/common/CallbackTrackerEntry.cc` so:

- `invoke_send_handler()` resets `send_event`
- `invoke_recv_handler()` resets `recv_event`

This prevents already-invoked callbacks from being freed a second time during
cleanup.

### 6. Made pending callback cleanup release tracked workload resources

Updated `network_frontend/analytical/common/CommonNetworkApi.cc` so cleanup
attempts to release workload-side tracked nodes before destroying pending
callback records.

This reduces false "unreleased hardware resource" reports during teardown for
callbacks that never completed normally.

### 7. Fixed subgroup collective scheduling scope

Further debugging showed that some collectives only involved subgroup ranks, but
the scheduler still synchronized them as if all `64` ranks had to participate.

That caused streams belonging to smaller communication groups to wait on ranks
that were never part of the collective, so the stream could become permanently
stuck in the first scheduling phase.

The fix was to make synchronization target size a per-stream property and use
the real communication-group participant count when deciding whether a stream
can be scheduled.

### 8. Fixed deterministic stream-id collisions across communication groups

Another issue was that deterministic `stream_id` generation only depended on
`workload_node_id`.

That was not unique enough once multiple communication groups issued collectives
for the same workload node. Different groups could reuse the same derived
stream/tag identity and create callback mismatches in the analytical backend.

The fix was to include:

- `workload_node_id`
- `comm_group_id`
- `stream_index`

in stream-id allocation.

### 9. Routed ready-list scheduling through `ask_for_schedule`

The scheduler path was also tightened so ready-list transitions use
`ask_for_schedule(...)` rather than calling `schedule(...)` directly.

That ensures the same group-aware scheduling checks are applied both when a
stream is first added to the ready list and when streams are removed.

### 10. Added analytical drain helpers for stranded work

The analytical frontend main loop now attempts to:

- reschedule stranded ready streams;
- issue dependency-free nodes that were left unissued;

before declaring the simulation quiescent.

This did not fully solve the run, but it removed some false-idle cases and made
the remaining failure mode smaller and easier to isolate.

## Validation Result

The document above originally stopped too early. After the newer fixes, the
result is improved but still not fully correct:

- `bash astra-sim/qwen_experiment/in_dc/run_analytical.sh` still exits with
  code `2`.
- The AddressSanitizer `heap-use-after-free` no longer occurs.
- The failure scope is much smaller than before.

The most important reduction is:

- before the subgroup-scheduling and stream-id fixes, the run ended with roughly
  `1312` pending callbacks and many stuck ranks in `16-31`;
- after those fixes, the run ends with `32` pending callbacks;
- ranks `16-31` now drain cleanly;
- the remaining stuck ranks are `0-15`.

## Remaining Problem

The run now fails in a narrower and more specific way.

At exit, the analytical backend still reports `32` pending callbacks, all with
the same basic signature:

- `send=0 recv=1 finished=0` for unmatched receive-side state;
- a small set of tags such as `501508608`, `516164096`, `552707392`,
  `552707456`, `552707520`, and `552707584`.

The stuck work is concentrated on ranks `0-15`, which still show:

- `ready_list=0`
- `total_running=4`
- `first_phase=4`

while ranks `16-31` already report zero running streams.

Final teardown also still reports unreleased GPU communication nodes on ranks
`0-15`, mainly:

- node `6434`
- node `184`
- node `1973`

These ET nodes map to collectives such as:

- subgroup `REDUCE_SCATTER` on process groups `17-20`
- subgroup `ALL_GATHER` on process groups `17-20`
- a broader `ALL_REDUCE`-style collective on process groups `1-4`

So the unresolved issue is no longer the generic resource model and no longer
the earlier all-ranks synchronization bug. The remaining problem is inside
collective convergence for a smaller set of early subgroup/global collectives.

## Current Conclusion

The work completed here solved several real problems:

- hardware resource handling is now configurable and not hardcoded;
- recv pressure is bounded and visible;
- analytical cleanup no longer crashes with use-after-free.
- subgroup collectives are no longer blocked by an implicit all-`64`-ranks
  synchronization rule;
- deterministic stream ids no longer collide across communication groups.

Those fixes materially changed the failure profile, which is strong evidence
that they were real root causes.

What remains is a deeper communication convergence bug. The evidence now points
to incomplete progress/termination inside a subset of collective algorithms or
their analytical callback matching path, rather than to shell scripting,
resource accounting, or the earlier stream-identification problem.

## Recommended Next Step

Focus the next round of debugging on the remaining collectives that still do not
drain:

1. trace the remaining pending tags back to ET nodes `6434`, `184`, and
   `1973`;
2. inspect ring / halving-doubling progression for these collectives,
   especially later chunk completion and receive-side callback release;
3. verify that the analytical backend produces symmetric send/recv completion
   for the subgroup process groups `17-20` and the global group `1-4`;
4. inspect why ranks `0-15` remain in `first_phase=4` with no ready-list work
   even though their peers have already drained.
