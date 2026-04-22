# csg-htsim upstream sync notes

Current pin: `841d9e7be46bb968eece766aa4b6c044c7799f67` (anchor: "Revised connection_matrix.h/cpp"), bumped on 2026-04-22. Previous pin: `67cbbbb1cccdbddc400803414127d044ecd55290`.

Upstream `origin/master` is ahead by 5 commits. Evaluation below (oldest first):

| SHA | Title | Files | Functional impact | Conflict w/ `htsim_astrasim.patch` | Verdict |
|---|---|---|---|---|---|
| `0639f63` | Added `_pausedClass` member into EthPausePacket | `sim/eth_pause_packet.h` (+3), `sim/tests/main_dumbell_tcp.cpp` (+1), `.gitignore` | Adds `getPausedClass()` / `setPausedClass(uint32_t)` and `uint32_t _pausedClass{0}` — pure addition, no ABI break for existing code. | None — touches only `eth_pause_packet.h`. | **Adopt** — prerequisite for §11.2 P3.1d (PFC multi-class). |
| `76cb62a` | Merge from upstream | 20 files; notably `fat_tree_topology.{cpp,h}` (+180 lines total), `eqds.{cpp,h}` (+1069 lines), sample `.cm` connection matrices, `leaf_spine_tiny.topo` | Big EQDS refactor + FatTree enhancements (queuesize-per-tier, leaf-spine variants). **Does not touch `sim/tcp.{cpp,h}`** so patch is safe. FatTree API additions are additive (new `set_tier_parameters`, etc., no removals). | None — patch touches only `sim/tcp.{cpp,h}`. | **Adopt** — we want FatTree's new tiered-queue capability for Phase 2/3. |
| `952f643` | Added `CNP` in `network.h` enum | `sim/network.h` (+1/-1) | Appends `CNP` after `EQDSRTS` in the `packet_type` enum. Enum values after append shift by 0 (CNP is last); any `switch` on `packet_type` without `default` would need updating — **not an issue for us, we don't switch on this enum**. | None. | **Adopt** — required for §11.2 P3.1b (DCQCN CNP packets). |
| `20b2297` | Added AddOn capability for trigger | `sim/datacenter/connection_matrix.{cpp,h}` (+5/+1), `sim/trigger.{cpp,h}` (+11/-1) | Two changes: (1) `connection.addOnTriggerSignal` bool with `addon` keyword in .cm parser; (2) `BarrierTrigger::activate(bool re_arm)` + `_n_members` to re-prime barriers. Also *relaxes* `assert(_targets.size() > 0)` → comment. The relaxed assert is a minor robustness regression but only fires for barriers without targets, which our code doesn't create. | None. | **Adopt** — the re-arm barrier is directly reusable as the OCS "epoch boundary" trigger in §11.4 (`GenericCustomTopology::schedule_link_change`). Saves us from implementing a custom `EventSource` for OCS. |
| `841d9e7` | Revised connection_matrix.h/cpp | `sim/datacenter/connection_matrix.{cpp,h}` (+3/-3) | Comment-only: strips `// Fong` annotations. Zero functional diff. | None. | **Adopt** — no risk. |

## Patch-compatibility check

As of 2026-04-22 evening (§19 session — P4, P5, U3 landed), `build/astra_htsim/htsim_astrasim.patch` now touches **14 files** (804 lines):

- `sim/clock.cpp` — Clock progress-dot gating (verbose-only)
- `sim/hpcc.cpp`, `sim/hpcc.h` — HPCC flow-finish hooks, _link_info → std::vector (P4)
- `sim/hpccpacket.cpp`, `sim/hpccpacket.h` — HPCC _int_info → std::vector (P4)
- `sim/network.h` — `has_ingress_queue()` non-assert probe
- `sim/pipe.h` — `setDelay()` public (for OCS)
- `sim/queue.h` — `setBitrate()`, `bitrate()` public (for OCS)
- `sim/queue_lossless_input.cpp`, `sim/queue_lossless_output.cpp` — PFC / LosslessQueue patches + HPCC INT vector growth
- `sim/roce.cpp`, `sim/roce.h` — flow-finish hooks, deterministic seed, DCQCN AIMD state machine (U3), ECN_ECHO-aware send_ack
- `sim/tcp.cpp`, `sim/tcp.h` — flow-finish hooks

Patch is fully idempotent against upstream `841d9e7`. Any submodule bump must re-verify by running `build/astra_htsim/build.sh` and confirming the three integration tests pass (`test_hpcc.sh`, `test_dcqcn.sh`, `test_ocs_mutator.sh`).

## Bump results (2026-04-22)

- Submodule reset (`git checkout -- sim/tcp.cpp sim/tcp.h`) then `git fetch origin && git checkout 841d9e7`.
- `build/astra_htsim/build.sh` completed in ~40s on full rebuild (csg-htsim `make` + CMake).
- The regenerated `htsim_astrasim.patch` (with verbose gating from §11.3 #3) applied forward against the new tree without any rejected hunk — confirmed by "HTSim patch applied successfully" line in build log.
- No new compile errors. Same fmt/spdlog ODR warning as before (unrelated to the bump).
- Phase 0 smoke (16-NPU ring all-gather) passes: max cycle 2,827,437; wall time 0.14s — matches pre-bump numbers within the expected ±0.3% rank-level variance from random path selection.

## Downstream impact on our roadmap

- §11.4 (`GenericCustomTopology` with OCS mutator): after the bump, the OCS mutator can be layered on `BarrierTrigger::activate(true)` instead of rolling a new `EventSource`. Saves ~0.5 week of Phase 1 effort.
- §11.2 P3.1b (DCQCN): `CNP` enum value is prerequisite — without the bump, we'd have to add the enum entry ourselves (minor).
- §11.2 P3.1d (PFC): `EthPausePacket::_pausedClass` is prerequisite for any multi-priority PFC (3 priority classes minimum for RoCE). Without it we're single-class only.

## Stability policy after bump

Per §11.1 decision: future submodule bumps must go through Phase 4 CI smoke before being pinned. The CI harness (`utils/htsim_smoke.sh`) will be added in Phase 4.
