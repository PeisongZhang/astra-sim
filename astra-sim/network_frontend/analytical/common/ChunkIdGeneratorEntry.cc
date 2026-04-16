/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "common/ChunkIdGeneratorEntry.hh"
#include <cassert>

using namespace AstraSimAnalytical;

ChunkIdGeneratorEntry::ChunkIdGeneratorEntry() noexcept
    : next_id(0) {}

int ChunkIdGeneratorEntry::allocate_id() noexcept {
    assert(next_id >= 0);
    return next_id++;
}
