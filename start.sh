#!/bin/bash

## install submodules
git submodule update --init --recursive 

## build
./build/astra_analytical/build.sh
./build/astra_ns3/build.sh -c

