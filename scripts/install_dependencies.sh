#!/bin/bash

echo "=========================================="
echo "  Installing Dependencies for Raspberry Pi"
echo "=========================================="

# Update system
echo "Updating system..."
sudo apt update

# Install build tools
echo "Installing build tools..."
sudo apt install -y build-essential cmake git pkg-config

# Install GStreamer
echo "Installing GStreamer..."
sudo apt install -y \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-nice \
    gstreamer1.0-x \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    libnice-dev \
    libsrtp2-dev

# Install WebSocket and JSON libraries
echo "Installing WebSocket and JSON libraries..."
sudo apt install -y \
    libwebsocketpp-dev \
    libboost-all-dev \
    libjsoncpp-dev \
    libssl-dev

# Install camera and audio tools
echo "Installing camera and audio tools..."
sudo apt install -y \
    v4l-utils \
    alsa-utils \
    pulseaudio

# Install libcamera for Raspberry Pi CSI Camera support (OV5647, IMX219, etc.)
echo "Installing libcamera for Pi Camera Module..."
sudo apt install -y \
    libcamera-apps \
    libcamera-dev \
    gstreamer1.0-libcamera

# Enable camera interface
echo "Checking camera configuration..."
if grep -q "^start_x=1" /boot/config.txt 2>/dev/null || grep -q "^camera_auto_detect=1" /boot/firmware/config.txt 2>/dev/null; then
    echo "Camera already enabled in config"
else
    echo "Note: You may need to enable the camera interface:"
    echo "  - Run: sudo raspi-config"
    echo "  - Go to: Interface Options -> Camera -> Enable"
    echo "  - Or add 'camera_auto_detect=1' to /boot/firmware/config.txt (Bookworm)"
    echo "  - Reboot after enabling"
fi

# Install Node.js (for signaling server)
echo "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

# Install ngrok
echo "Installing ngrok..."
cd ~
wget https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz
tar -xzf ngrok-v3-stable-linux-arm64.tgz
sudo mv ngrok /usr/local/bin/
rm ngrok-v3-stable-linux-arm64.tgz

echo ""
echo "=========================================="
echo "  Installation completed!"
echo "=========================================="
echo "Next steps:"
echo "1. Sign up at https://ngrok.com and get authtoken"
echo "2. Run: ngrok config add-authtoken YOUR_TOKEN"
echo "3. Run: ./scripts/build.sh to build the C++ app"
echo "=========================================="
