#!/bin/bash

echo "======================================"
echo "  Building WebRTC Streamer"
echo "======================================"

# Create build directory
mkdir -p build
cd build

# Run CMake
echo "Running CMake..."
cmake .. || { echo "CMake failed"; exit 1; }

# Build
echo "Building..."
make -j$(nproc) || { echo "Build failed"; exit 1; }

echo ""
echo "======================================"
echo "  Build completed successfully!"
echo "======================================"
echo "Executable: build/webrtc_streamer"
echo "======================================"
