/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#pragma once

namespace AstraSimAnalytical {

/**
 * ChunkIdGeneratorEntry tracks the chunk id generated
 * for sim_send() and sim_recv() calls
 * per each (tag, src, dest, chunk_size) tuple.
 */
class ChunkIdGeneratorEntry {
  public:
    /**
     * Constructur.
     */
    ChunkIdGeneratorEntry() noexcept;

    /**
     * Allocate a new chunk id for the next unmatched send/recv operation.
     *
     * @return newly allocated chunk id
     */
    [[nodiscard]] int allocate_id() noexcept;

  private:
    /// next chunk id to be allocated for this key
    int next_id;
};

}  // namespace AstraSimAnalytical
