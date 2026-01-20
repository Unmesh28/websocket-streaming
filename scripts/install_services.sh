#!/bin/bash
# Install systemd services for auto-start on boot
# Run with: sudo ./install_services.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root: sudo $0${NC}"
    exit 1
fi

# Get the actual user (not root)
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Installing Auto-Start Services${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Project directory: $PROJECT_DIR"
echo "User: $ACTUAL_USER"
echo ""

# ============ Signaling Server Service ============
echo -e "${YELLOW}[1/3] Creating signaling server service...${NC}"

cat > /etc/systemd/system/pi-signaling.service << EOF
[Unit]
Description=Pi Camera WebRTC Signaling Server
After=network.target

[Service]
Type=simple
User=$ACTUAL_USER
WorkingDirectory=$PROJECT_DIR/signaling
ExecStart=/usr/bin/node $PROJECT_DIR/signaling/server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=8080

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}   Created pi-signaling.service${NC}"

# ============ WebRTC Streamer Service ============
echo -e "${YELLOW}[2/3] Creating WebRTC streamer service...${NC}"

cat > /etc/systemd/system/pi-streamer.service << EOF
[Unit]
Description=Pi Camera WebRTC Streamer
After=network.target pi-signaling.service
Requires=pi-signaling.service

[Service]
Type=simple
User=$ACTUAL_USER
WorkingDirectory=$PROJECT_DIR/build
ExecStart=$PROJECT_DIR/build/webrtc_streamer
Restart=always
RestartSec=10
# Allow camera access
SupplementaryGroups=video

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}   Created pi-streamer.service${NC}"

# ============ Combined Service (optional) ============
echo -e "${YELLOW}[3/3] Creating combined target...${NC}"

cat > /etc/systemd/system/pi-camera.target << EOF
[Unit]
Description=Pi Camera Streaming Stack
Requires=pi-signaling.service pi-streamer.service
After=pi-signaling.service pi-streamer.service

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}   Created pi-camera.target${NC}"

# Reload systemd
echo ""
echo -e "${YELLOW}Reloading systemd...${NC}"
systemctl daemon-reload

# Enable services
echo -e "${YELLOW}Enabling services...${NC}"
systemctl enable pi-signaling.service
systemctl enable pi-streamer.service
systemctl enable pi-camera.target

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  INSTALLATION COMPLETE!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Services installed:${NC}"
echo "  - pi-signaling.service  (Node.js signaling server)"
echo "  - pi-streamer.service   (WebRTC camera streamer)"
echo "  - pi-camera.target      (Combined target)"
echo ""
echo -e "${YELLOW}Commands:${NC}"
echo ""
echo "  Start all:     sudo systemctl start pi-camera.target"
echo "  Stop all:      sudo systemctl stop pi-camera.target"
echo "  Status:        sudo systemctl status pi-signaling pi-streamer"
echo ""
echo "  View logs:     journalctl -u pi-signaling -f"
echo "                 journalctl -u pi-streamer -f"
echo ""
echo -e "${YELLOW}For Cloudflare tunnel:${NC}"
echo "  If you haven't already, run:"
echo "    ./scripts/setup_permanent_tunnel.sh"
echo ""
echo "  Then the tunnel service (cloudflared) will handle the public URL."
echo ""
echo -e "${GREEN}Services will start automatically on boot!${NC}"
echo ""
