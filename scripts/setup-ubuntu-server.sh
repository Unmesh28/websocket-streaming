#!/bin/bash
#
# Ubuntu Server Setup Script for Pi Camera Signaling
# Run this on your Ubuntu server with a public IP
#

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Pi Camera Signaling Server - Ubuntu Setup Script       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Configuration
PORT=${PORT:-8080}
INSTALL_DIR="$HOME/pi-camera-signaling"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================
# STEP 1: Check and Open Firewall Ports
# ============================================================
print_step "Checking firewall status..."

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  FIREWALL / PORT CONFIGURATION"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Required ports to open:"
echo "  - Port $PORT (TCP) - Signaling server (HTTP + WebSocket)"
echo ""

# Check if UFW is installed and active
if command -v ufw &> /dev/null; then
    echo "UFW firewall detected."

    # Check UFW status
    UFW_STATUS=$(sudo ufw status | head -1)
    echo "Current status: $UFW_STATUS"

    if [[ "$UFW_STATUS" == *"active"* ]]; then
        echo ""
        echo "Current UFW rules:"
        sudo ufw status numbered
        echo ""

        # Check if port is already open
        if sudo ufw status | grep -q "$PORT"; then
            echo -e "${GREEN}Port $PORT is already open${NC}"
        else
            echo "Opening port $PORT..."
            sudo ufw allow $PORT/tcp comment 'Pi Camera Signaling'
            echo -e "${GREEN}Port $PORT opened successfully${NC}"
        fi
    else
        print_warning "UFW is installed but not active"
        echo "To enable UFW and open the port, run:"
        echo "  sudo ufw enable"
        echo "  sudo ufw allow $PORT/tcp"
    fi

# Check for firewalld (CentOS/RHEL/Fedora)
elif command -v firewall-cmd &> /dev/null; then
    echo "firewalld detected."

    if systemctl is-active --quiet firewalld; then
        echo "Opening port $PORT..."
        sudo firewall-cmd --permanent --add-port=$PORT/tcp
        sudo firewall-cmd --reload
        echo -e "${GREEN}Port $PORT opened successfully${NC}"
    else
        print_warning "firewalld is not running"
    fi

# Check for iptables
elif command -v iptables &> /dev/null; then
    echo "iptables detected."
    echo ""
    echo "To open port $PORT with iptables, run:"
    echo "  sudo iptables -A INPUT -p tcp --dport $PORT -j ACCEPT"
    echo "  sudo iptables-save | sudo tee /etc/iptables.rules"
    echo ""

else
    print_warning "No firewall detected. Port should be accessible."
fi

# Check if port is actually listening
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  PORT CHECK COMMANDS"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Useful commands to check ports:"
echo ""
echo "  # Check if port is open locally:"
echo "  sudo netstat -tlnp | grep $PORT"
echo "  # or"
echo "  sudo ss -tlnp | grep $PORT"
echo ""
echo "  # Check firewall rules (UFW):"
echo "  sudo ufw status verbose"
echo ""
echo "  # Test port from outside (run from another machine):"
echo "  nc -zv YOUR_SERVER_IP $PORT"
echo "  # or"
echo "  curl -v http://YOUR_SERVER_IP:$PORT/health"
echo ""

# Cloud provider firewall warning
echo "═══════════════════════════════════════════════════════════"
echo "  CLOUD PROVIDER FIREWALL WARNING"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC} If using a cloud provider (AWS, GCP, Azure, DigitalOcean),"
echo "you ALSO need to open the port in their security group/firewall:"
echo ""
echo "  AWS:          Security Groups → Inbound Rules → Add port $PORT"
echo "  GCP:          VPC Network → Firewall → Create rule for port $PORT"
echo "  Azure:        Network Security Group → Add inbound rule"
echo "  DigitalOcean: Networking → Firewalls → Add rule"
echo "  Vultr:        Firewall → Add rule for port $PORT"
echo ""

# ============================================================
# STEP 2: Install Node.js
# ============================================================
print_step "Checking Node.js installation..."

if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    echo "Node.js already installed: $NODE_VERSION"

    # Check if version is 18+
    MAJOR_VERSION=$(echo $NODE_VERSION | cut -d'.' -f1 | tr -d 'v')
    if [ "$MAJOR_VERSION" -lt 18 ]; then
        print_warning "Node.js version is below 18. Upgrading..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi
else
    echo "Installing Node.js 18..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

echo "Node.js version: $(node --version)"
echo "npm version: $(npm --version)"

# ============================================================
# STEP 3: Create Project Directory
# ============================================================
print_step "Creating project directory at $INSTALL_DIR..."

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ============================================================
# STEP 4: Create package.json
# ============================================================
print_step "Creating package.json..."

cat > package.json << 'EOF'
{
  "name": "pi-camera-signaling",
  "version": "1.0.0",
  "description": "WebRTC signaling server for Pi Camera streaming",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "ws": "^8.14.2",
    "express": "^4.18.2"
  }
}
EOF

# ============================================================
# STEP 5: Install npm dependencies
# ============================================================
print_step "Installing npm dependencies..."

npm install

# ============================================================
# STEP 6: Prompt for Cloudflare credentials
# ============================================================
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  CLOUDFLARE TURN CREDENTIALS"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "You need Cloudflare TURN credentials for NAT traversal."
echo "Get them from: https://dash.cloudflare.com → Calls"
echo ""

read -p "Enter Cloudflare TURN Key ID (or press Enter to skip): " TURN_ID
read -p "Enter Cloudflare API Token (or press Enter to skip): " TURN_TOKEN

if [ -n "$TURN_ID" ] && [ -n "$TURN_TOKEN" ]; then
    cat > .env << EOF
PORT=$PORT
CLOUDFLARE_TURN_ID=$TURN_ID
CLOUDFLARE_TURN_TOKEN=$TURN_TOKEN
EOF
    echo -e "${GREEN}Credentials saved to .env${NC}"
else
    cat > .env << EOF
PORT=$PORT
CLOUDFLARE_TURN_ID=YOUR_TURN_ID_HERE
CLOUDFLARE_TURN_TOKEN=YOUR_TURN_TOKEN_HERE
EOF
    print_warning "Credentials not provided. Edit .env file later."
fi

# ============================================================
# STEP 7: Copy server files
# ============================================================
print_step "Server files will be copied from the repository..."

echo ""
echo "Copy the following files to $INSTALL_DIR:"
echo "  - server.js (from signaling/server.js)"
echo "  - public/index.html (web viewer)"
echo ""
echo "Or copy from the repository:"
echo "  cp ~/websocket-streaming/signaling/server.js $INSTALL_DIR/"
echo "  cp -r ~/websocket-streaming/web $INSTALL_DIR/public"
echo ""

# ============================================================
# FINAL SUMMARY
# ============================================================
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    SETUP COMPLETE                          ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  Installation directory: $INSTALL_DIR"
echo "║                                                            ║"
echo "║  Next steps:                                               ║"
echo "║  1. Edit .env with your Cloudflare credentials             ║"
echo "║  2. Copy server.js to this directory                       ║"
echo "║  3. Start the server:                                      ║"
echo "║     cd $INSTALL_DIR && source .env && node server.js"
echo "║                                                            ║"
echo "║  To run as a service (recommended):                        ║"
echo "║     pm2 start server.js --name pi-signaling                ║"
echo "║     pm2 save && pm2 startup                                ║"
echo "║                                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Server URL for Pi streamer: ws://$(hostname -I | awk '{print $1}'):$PORT"
echo "Web viewer URL: http://$(hostname -I | awk '{print $1}'):$PORT"
echo ""
