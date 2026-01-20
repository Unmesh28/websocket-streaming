#!/bin/bash
# Start WebRTC streamer with Cloudflare Quick Tunnel
# This gives you a random *.trycloudflare.com URL each time

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  WebRTC Streamer with Cloudflare Tunnel${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if cloudflared is installed
if ! command -v cloudflared &> /dev/null; then
    echo -e "${RED}cloudflared not found! Installing...${NC}"

    # Detect architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ]; then
        CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    elif [ "$ARCH" = "armv7l" ]; then
        CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
    else
        CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    fi

    curl -L "$CLOUDFLARED_URL" -o /tmp/cloudflared
    chmod +x /tmp/cloudflared
    sudo mv /tmp/cloudflared /usr/local/bin/
    echo -e "${GREEN}cloudflared installed!${NC}"
fi

# Function to cleanup on exit
cleanup() {
    echo ""
    echo -e "${YELLOW}Shutting down...${NC}"

    # Kill background jobs
    if [ -n "$SIGNALING_PID" ]; then
        kill $SIGNALING_PID 2>/dev/null || true
    fi
    if [ -n "$TUNNEL_PID" ]; then
        kill $TUNNEL_PID 2>/dev/null || true
    fi
    if [ -n "$STREAMER_PID" ]; then
        kill $STREAMER_PID 2>/dev/null || true
    fi

    echo -e "${GREEN}Cleanup complete${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Start signaling server in background
echo -e "${YELLOW}Starting signaling server...${NC}"
cd "$PROJECT_DIR/signaling-server"
npm start > /tmp/signaling.log 2>&1 &
SIGNALING_PID=$!
sleep 2

# Check if signaling server started
if ! kill -0 $SIGNALING_PID 2>/dev/null; then
    echo -e "${RED}Failed to start signaling server!${NC}"
    cat /tmp/signaling.log
    exit 1
fi
echo -e "${GREEN}Signaling server running (PID: $SIGNALING_PID)${NC}"

# Start cloudflared tunnel and capture the URL
echo -e "${YELLOW}Starting Cloudflare tunnel...${NC}"
TUNNEL_LOG="/tmp/cloudflared.log"

# Start cloudflared and log output
cloudflared tunnel --url http://localhost:8080 > "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

# Wait for tunnel URL to appear in logs
echo -e "${YELLOW}Waiting for tunnel URL...${NC}"
TUNNEL_URL=""
for i in {1..30}; do
    if [ -f "$TUNNEL_LOG" ]; then
        TUNNEL_URL=$(grep -o 'https://[^[:space:]]*\.trycloudflare\.com' "$TUNNEL_LOG" | head -1)
        if [ -n "$TUNNEL_URL" ]; then
            break
        fi
    fi
    sleep 1
done

if [ -z "$TUNNEL_URL" ]; then
    echo -e "${RED}Failed to get tunnel URL!${NC}"
    cat "$TUNNEL_LOG"
    cleanup
    exit 1
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  TUNNEL IS READY!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Public URL:${NC} ${GREEN}$TUNNEL_URL${NC}"
echo ""
echo -e "${YELLOW}Instructions:${NC}"
echo "1. Start the C++ streamer in another terminal:"
echo "   cd $PROJECT_DIR/build && ./webrtc_streamer"
echo ""
echo "2. Open this URL on any device:"
echo "   ${GREEN}$TUNNEL_URL${NC}"
echo ""
echo "3. The viewer will auto-connect to the stream"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop all services${NC}"
echo ""

# Keep running and show logs
tail -f "$TUNNEL_LOG" /tmp/signaling.log 2>/dev/null
