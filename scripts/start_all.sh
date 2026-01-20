#!/bin/bash
# Start everything: Signaling Server + Cloudflare Tunnel + WebRTC Streamer
# Usage: ./start_all.sh [quick|permanent]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MODE="${1:-auto}"

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Shutting down all services...${NC}"

    [ -n "$SIGNALING_PID" ] && kill $SIGNALING_PID 2>/dev/null || true
    [ -n "$TUNNEL_PID" ] && kill $TUNNEL_PID 2>/dev/null || true
    [ -n "$STREAMER_PID" ] && kill $STREAMER_PID 2>/dev/null || true

    # Also kill by name as backup
    pkill -f "node server.js" 2>/dev/null || true
    pkill -f "cloudflared tunnel" 2>/dev/null || true
    pkill -f "webrtc_streamer" 2>/dev/null || true

    echo -e "${GREEN}All services stopped${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     Raspberry Pi WebRTC Streamer - Complete Startup       ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check if cloudflared is installed
if ! command -v cloudflared &> /dev/null; then
    echo -e "${YELLOW}Installing cloudflared...${NC}"
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ]; then
        URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    elif [ "$ARCH" = "armv7l" ]; then
        URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
    else
        URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    fi
    curl -sL "$URL" -o /tmp/cloudflared && chmod +x /tmp/cloudflared
    sudo mv /tmp/cloudflared /usr/local/bin/
    echo -e "${GREEN}cloudflared installed${NC}"
fi

# Check if streamer is built
if [ ! -f "$PROJECT_DIR/build/webrtc_streamer" ]; then
    echo -e "${RED}Streamer not built! Run: cd build && cmake .. && make${NC}"
    exit 1
fi

# Determine tunnel mode
if [ "$MODE" = "auto" ]; then
    if [ -f "$PROJECT_DIR/.tunnel_name" ]; then
        MODE="permanent"
    else
        MODE="quick"
    fi
fi

echo -e "${BLUE}Mode: ${MODE} tunnel${NC}"
echo ""

# ============ Start Signaling Server ============
echo -e "${YELLOW}[1/3] Starting signaling server...${NC}"
cd "$PROJECT_DIR/signaling-server"
npm start > /tmp/signaling.log 2>&1 &
SIGNALING_PID=$!
sleep 2

if ! kill -0 $SIGNALING_PID 2>/dev/null; then
    echo -e "${RED}Signaling server failed to start!${NC}"
    cat /tmp/signaling.log
    exit 1
fi
echo -e "${GREEN}      Signaling server running on port 8080${NC}"

# ============ Start Cloudflare Tunnel ============
echo -e "${YELLOW}[2/3] Starting Cloudflare tunnel...${NC}"

TUNNEL_LOG="/tmp/cloudflared.log"
> "$TUNNEL_LOG"

if [ "$MODE" = "permanent" ]; then
    TUNNEL_NAME=$(cat "$PROJECT_DIR/.tunnel_name" 2>/dev/null || echo "pi-camera")
    HOSTNAME=$(cat "$PROJECT_DIR/.tunnel_hostname" 2>/dev/null || echo "")

    cloudflared tunnel run "$TUNNEL_NAME" > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    sleep 3

    if [ -n "$HOSTNAME" ]; then
        TUNNEL_URL="https://$HOSTNAME"
    else
        TUNNEL_URL="(check cloudflared config)"
    fi
else
    # Quick tunnel
    cloudflared tunnel --url http://localhost:8080 > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!

    # Wait for URL
    for i in {1..30}; do
        TUNNEL_URL=$(grep -o 'https://[^[:space:]]*\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
        [ -n "$TUNNEL_URL" ] && break
        sleep 1
    done
fi

if [ -z "$TUNNEL_URL" ]; then
    echo -e "${RED}Failed to get tunnel URL!${NC}"
    tail -20 "$TUNNEL_LOG"
    exit 1
fi

echo -e "${GREEN}      Tunnel active: ${TUNNEL_URL}${NC}"

# ============ Start WebRTC Streamer ============
echo -e "${YELLOW}[3/3] Starting WebRTC streamer...${NC}"
cd "$PROJECT_DIR/build"
./webrtc_streamer > /tmp/streamer.log 2>&1 &
STREAMER_PID=$!
sleep 3

if ! kill -0 $STREAMER_PID 2>/dev/null; then
    echo -e "${RED}Streamer failed to start!${NC}"
    cat /tmp/streamer.log
    exit 1
fi
echo -e "${GREEN}      WebRTC streamer running${NC}"

# ============ Show Status ============
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}ALL SERVICES RUNNING!${NC}                                    ${CYAN}║${NC}"
echo -e "${CYAN}╠═══════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}                                                             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${YELLOW}Public URL:${NC}                                               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}$TUNNEL_URL${NC}"
echo -e "${CYAN}║${NC}                                                             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${YELLOW}Open this URL on any device (phone, laptop, etc.)${NC}        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${BLUE}Services:${NC}                                                 ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    - Signaling:  localhost:8080 (PID: $SIGNALING_PID)              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    - Tunnel:     cloudflared (PID: $TUNNEL_PID)                    ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    - Streamer:   webrtc_streamer (PID: $STREAMER_PID)              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                             ${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop all services${NC}"
echo ""
echo -e "${BLUE}Logs (streamer):${NC}"
echo "─────────────────────────────────────────────────────────────"

# Show streamer logs
tail -f /tmp/streamer.log
