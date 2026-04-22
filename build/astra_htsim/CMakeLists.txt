# CMake Requirement
cmake_minimum_required(VERSION 3.15)

# C++ requirement
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Set the build type to Release if not specified
if (NOT CMAKE_BUILD_TYPE)
	set(CMAKE_BUILD_TYPE Release)
endif ()
# set(CMAKE_CXX_FLAGS_DEBUG "-O0 -Wall -Wextra -Wuninitialized -Wunused-function -Wno-unused-parameter -Wno-empty-body -fsanitize=address,undefined,leak -g")
set(CMAKE_CXX_FLAGS_DEBUG "-O0 -Wall -Wextra -Wuninitialized -Wunused-function -Wno-unused-parameter -Wno-empty-body -g")
# Release: per §11.3 lever #1, enable -march=native + -DNDEBUG. LTO is skipped because
# fmt and spdlog ship two versions in this tree (extern/helper/fmt vs extern/helper/spdlog/fmt)
# whose `detail::buffer<T>` layouts differ — LTO merges them into one ODR violation and
# segfaults on first flow. Re-evaluate after unifying the fmt vendoring.
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG -march=native")

# TODO: Remove this once binary_function deprecation is resolved.
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-error")

# Setup project
project(AstraSim_HTSim)

# Compilation target
set(BUILDTARGET "all" CACHE STRING "Compilation target ([all])")

# Compile AstraSim library
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../ AstraSim)

# build appropriate htsim network backend as library
set(NETWORK_BACKEND_BUILD_AS_LIBRARY ON)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../extern/network_backend/analytical/ Analytical)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../astra-sim/network_frontend/htsim/ AstraSim_HTSim)
# add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../extern/network_backend/csg-htsim/sim htsim)
