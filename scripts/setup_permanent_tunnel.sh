#!/bin/bash
# Setup Cloudflare Permanent Tunnel
# Run this once to create a tunnel with a fixed URL

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$HOME/.cloudflared"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Permanent Cloudflare Tunnel Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if cloudflared is installed
if ! command -v cloudflared &> /dev/null; then
    echo -e "${RED}cloudflared not found! Installing...${NC}"
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

echo ""
echo -e "${YELLOW}Step 1: Login to Cloudflare${NC}"
echo "This will open a browser to authorize cloudflared"
echo ""

# Check if already logged in
if [ -f "$CONFIG_DIR/cert.pem" ]; then
    echo -e "${GREEN}Already logged in to Cloudflare${NC}"
else
    cloudflared tunnel login
fi

echo ""
echo -e "${YELLOW}Step 2: Create tunnel${NC}"
read -p "Enter tunnel name (e.g., pi-camera): " TUNNEL_NAME

if [ -z "$TUNNEL_NAME" ]; then
    TUNNEL_NAME="pi-camera"
fi

# Check if tunnel already exists
EXISTING_TUNNEL=$(cloudflared tunnel list | grep -w "$TUNNEL_NAME" | awk '{print $1}' || true)

if [ -n "$EXISTING_TUNNEL" ]; then
    echo -e "${YELLOW}Tunnel '$TUNNEL_NAME' already exists (ID: $EXISTING_TUNNEL)${NC}"
    TUNNEL_ID="$EXISTING_TUNNEL"
else
    echo "Creating tunnel '$TUNNEL_NAME'..."
    cloudflared tunnel create "$TUNNEL_NAME"
    TUNNEL_ID=$(cloudflared tunnel list | grep -w "$TUNNEL_NAME" | awk '{print $1}')
fi

echo -e "${GREEN}Tunnel ID: $TUNNEL_ID${NC}"

echo ""
echo -e "${YELLOW}Step 3: Configure DNS${NC}"
echo ""
echo "You need a domain added to Cloudflare."
echo "Enter the hostname you want to use (e.g., camera.yourdomain.com)"
echo ""
read -p "Hostname: " HOSTNAME

if [ -z "$HOSTNAME" ]; then
    echo -e "${RED}Hostname is required!${NC}"
    exit 1
fi

# Add DNS route
echo "Adding DNS route..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" || true

echo ""
echo -e "${YELLOW}Step 4: Create config file${NC}"

mkdir -p "$CONFIG_DIR"

# Find credentials file
CRED_FILE=$(ls "$CONFIG_DIR"/*.json 2>/dev/null | grep "$TUNNEL_ID" | head -1 || true)

if [ -z "$CRED_FILE" ]; then
    CRED_FILE="$CONFIG_DIR/$TUNNEL_ID.json"
fi

cat > "$CONFIG_DIR/config.yml" << EOF
tunnel: $TUNNEL_NAME
credentials-file: $CRED_FILE

ingress:
  - hostname: $HOSTNAME
    service: http://localhost:8080
  - service: http_status:404
EOF

echo -e "${GREEN}Config file created at $CONFIG_DIR/config.yml${NC}"

echo ""
echo -e "${YELLOW}Step 5: Test the tunnel${NC}"
echo ""
echo "To test the tunnel, run:"
echo "  cloudflared tunnel run $TUNNEL_NAME"
echo ""

read -p "Would you like to install as a system service? (y/n): " INSTALL_SERVICE

if [ "$INSTALL_SERVICE" = "y" ] || [ "$INSTALL_SERVICE" = "Y" ]; then
    echo ""
    echo -e "${YELLOW}Installing as system service...${NC}"
    sudo cloudflared service install
    sudo systemctl enable cloudflared
    echo -e "${GREEN}Service installed!${NC}"
    echo ""
    echo "Start with: sudo systemctl start cloudflared"
    echo "Stop with:  sudo systemctl stop cloudflared"
    echo "Status:     sudo systemctl status cloudflared"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  SETUP COMPLETE!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Your permanent URL: ${GREEN}https://$HOSTNAME${NC}"
echo ""
echo -e "${YELLOW}To start streaming:${NC}"
echo "1. Start the tunnel:  cloudflared tunnel run $TUNNEL_NAME"
echo "   (or if installed as service: sudo systemctl start cloudflared)"
echo ""
echo "2. Start signaling:   cd $PROJECT_DIR && ./scripts/start_signaling.sh"
echo ""
echo "3. Start streamer:    cd $PROJECT_DIR/build && ./webrtc_streamer"
echo ""
echo "4. Open: https://$HOSTNAME"
echo ""

# Save config for other scripts
echo "$HOSTNAME" > "$PROJECT_DIR/.tunnel_hostname"
echo "$TUNNEL_NAME" > "$PROJECT_DIR/.tunnel_name"
