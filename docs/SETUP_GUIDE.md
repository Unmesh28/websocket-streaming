# Pi Camera WebRTC Streaming - Setup Guide

## Architecture Overview

```
┌─────────────────┐         ┌─────────────────────────┐         ┌─────────────────┐
│   Raspberry Pi  │         │     Ubuntu Server       │         │     Viewer      │
│                 │         │    (Public IP)          │         │  (Phone/Browser)│
│  ┌───────────┐  │         │  ┌─────────────────┐    │         │                 │
│  │ C++ WebRTC│  │ ──────► │  │ Signaling Server│ ◄──┼─────────│                 │
│  │ Streamer  │  │  WS     │  │   (Node.js)     │    │   WS    │                 │
│  └───────────┘  │         │  └─────────────────┘    │         │                 │
│        │        │         │          │              │         │                 │
│        │        │         │    TURN credentials     │         │                 │
│        ▼        │         └─────────────────────────┘         │                 │
│   Camera Feed   │                    │                        │                 │
│                 │                    │                        │                 │
└────────┬────────┘                    │                        └────────┬────────┘
         │                             │                                 │
         │         ┌───────────────────┴───────────────────┐             │
         │         │        Cloudflare TURN Server         │             │
         └────────►│     (Media relay for NAT traversal)   │◄────────────┘
                   └───────────────────────────────────────┘
                              WebRTC Media Flow
```

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Signaling Server | Ubuntu Server (public IP) | WebSocket server for SDP/ICE exchange |
| C++ Streamer | Raspberry Pi | Captures camera, encodes H264, sends WebRTC |
| TURN Server | Cloudflare | Relays media when direct P2P fails |
| Viewer | Any device | Browser/App that receives the stream |

## Requirements

### Ubuntu Server
- Ubuntu 20.04+ with public IP
- Node.js 18+
- Open ports: 8080 (or your chosen port)

### Raspberry Pi
- Raspberry Pi 4 (recommended) or Pi 3
- Raspberry Pi OS (64-bit recommended)
- Camera module (IR or regular)
- GStreamer and WebRTC libraries

### Cloudflare Account
- Free account for TURN credentials
- API token with "Calls: Edit" permission

---

## Step 1: Ubuntu Server Setup

### 1.1 Install Node.js

```bash
# SSH into your Ubuntu server
ssh user@YOUR_SERVER_IP

# Install Node.js 18+
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Verify installation
node --version  # Should be v18+
npm --version
```

### 1.2 Create Project Directory

```bash
mkdir -p ~/pi-camera-signaling
cd ~/pi-camera-signaling
```

### 1.3 Create Signaling Server

Create `package.json`:
```bash
cat > package.json << 'EOF'
{
  "name": "pi-camera-signaling",
  "version": "1.0.0",
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
```

Create `server.js`:
```bash
cat > server.js << 'EOF'
const express = require('express');
const { WebSocketServer } = require('ws');
const http = require('http');
const path = require('path');

// ============== CONFIGURATION ==============
const PORT = process.env.PORT || 8080;

// Cloudflare TURN credentials (get from Cloudflare dashboard)
const CLOUDFLARE_TURN_ID = process.env.CLOUDFLARE_TURN_ID || 'YOUR_TURN_ID';
const CLOUDFLARE_TURN_TOKEN = process.env.CLOUDFLARE_TURN_TOKEN || 'YOUR_TURN_TOKEN';

// ============================================

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

// Store connections
const broadcasters = new Map();  // streamId -> ws
const viewers = new Map();       // viewerId -> { ws, streamId }
let viewerCounter = 0;

// Serve static files (web viewer)
app.use(express.static(path.join(__dirname, 'public')));

// TURN credentials endpoint
app.get('/turn-credentials', async (req, res) => {
    try {
        const response = await fetch(
            `https://rtc.live.cloudflare.com/v1/turn/keys/${CLOUDFLARE_TURN_ID}/credentials/generate`,
            {
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${CLOUDFLARE_TURN_TOKEN}`,
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ ttl: 86400 })
            }
        );

        if (!response.ok) {
            throw new Error(`Cloudflare API error: ${response.status}`);
        }

        const data = await response.json();

        res.json({
            iceServers: [
                { urls: 'stun:stun.l.google.com:19302' },
                { urls: 'stun:stun.cloudflare.com:3478' },
                {
                    urls: 'turn:turn.cloudflare.com:3478?transport=udp',
                    username: data.iceServers.username,
                    credential: data.iceServers.credential
                },
                {
                    urls: 'turn:turn.cloudflare.com:3478?transport=tcp',
                    username: data.iceServers.username,
                    credential: data.iceServers.credential
                },
                {
                    urls: 'turns:turn.cloudflare.com:5349?transport=tcp',
                    username: data.iceServers.username,
                    credential: data.iceServers.credential
                }
            ]
        });
    } catch (error) {
        console.error('TURN credentials error:', error);
        res.json({
            iceServers: [
                { urls: 'stun:stun.l.google.com:19302' },
                { urls: 'stun:stun.cloudflare.com:3478' }
            ]
        });
    }
});

// Health check
app.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        broadcasters: broadcasters.size,
        viewers: viewers.size
    });
});

// WebSocket handling
wss.on('connection', (ws) => {
    console.log('New WebSocket connection');

    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });

    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message.toString());
            handleMessage(ws, data);
        } catch (e) {
            console.error('Invalid message:', e);
        }
    });

    ws.on('close', () => {
        handleDisconnect(ws);
    });

    ws.on('error', (error) => {
        console.error('WebSocket error:', error);
    });
});

function handleMessage(ws, data) {
    const { type } = data;

    switch (type) {
        case 'register':
            handleRegister(ws, data);
            break;
        case 'join':
            handleJoin(ws, data);
            break;
        case 'offer':
            handleOffer(ws, data);
            break;
        case 'answer':
            handleAnswer(ws, data);
            break;
        case 'ice-candidate':
            handleIceCandidate(ws, data);
            break;
        default:
            console.log('Unknown message type:', type);
    }
}

function handleRegister(ws, data) {
    const streamId = data.stream_id;
    console.log(`Broadcaster registering: ${streamId}`);

    // Clean up existing broadcaster with same ID
    if (broadcasters.has(streamId)) {
        const oldWs = broadcasters.get(streamId);
        if (oldWs !== ws && oldWs.readyState === 1) {
            oldWs.close();
        }
    }

    ws.streamId = streamId;
    ws.isBroadcaster = true;
    broadcasters.set(streamId, ws);

    ws.send(JSON.stringify({
        type: 'registered',
        stream_id: streamId
    }));

    console.log(`Broadcaster registered: ${streamId}`);
}

function handleJoin(ws, data) {
    const streamId = data.stream_id;
    const viewerId = `viewer-${++viewerCounter}`;

    console.log(`Viewer ${viewerId} joining stream: ${streamId}`);

    // Check if previous viewer exists on this ws and clean up
    for (const [oldViewerId, viewer] of viewers.entries()) {
        if (viewer.ws === ws) {
            viewers.delete(oldViewerId);
            break;
        }
    }

    ws.viewerId = viewerId;
    ws.streamId = streamId;
    ws.isBroadcaster = false;
    viewers.set(viewerId, { ws, streamId });

    ws.send(JSON.stringify({
        type: 'joined',
        viewer_id: viewerId,
        stream_id: streamId
    }));

    // Notify broadcaster of new viewer
    const broadcaster = broadcasters.get(streamId);
    if (broadcaster && broadcaster.readyState === 1) {
        broadcaster.send(JSON.stringify({
            type: 'viewer-joined',
            viewer_id: viewerId
        }));
        console.log(`Notified broadcaster of viewer ${viewerId}`);
    } else {
        ws.send(JSON.stringify({
            type: 'error',
            message: 'Stream not available'
        }));
    }
}

function handleOffer(ws, data) {
    const viewerId = data.to;
    const viewer = viewers.get(viewerId);

    if (viewer && viewer.ws.readyState === 1) {
        viewer.ws.send(JSON.stringify({
            type: 'offer',
            from: ws.streamId,
            sdp: data.sdp
        }));
        console.log(`Offer sent to ${viewerId}`);
    }
}

function handleAnswer(ws, data) {
    const streamId = data.to;
    const broadcaster = broadcasters.get(streamId);

    if (broadcaster && broadcaster.readyState === 1) {
        broadcaster.send(JSON.stringify({
            type: 'answer',
            from: ws.viewerId,
            sdp: data.sdp
        }));
        console.log(`Answer sent to broadcaster from ${ws.viewerId}`);
    }
}

function handleIceCandidate(ws, data) {
    const target = data.to;

    if (ws.isBroadcaster) {
        // From broadcaster to viewer
        const viewer = viewers.get(target);
        if (viewer && viewer.ws.readyState === 1) {
            viewer.ws.send(JSON.stringify({
                type: 'ice-candidate',
                from: ws.streamId,
                candidate: data.candidate,
                sdpMid: data.sdpMid,
                sdpMLineIndex: data.sdpMLineIndex
            }));
        }
    } else {
        // From viewer to broadcaster
        const broadcaster = broadcasters.get(target);
        if (broadcaster && broadcaster.readyState === 1) {
            broadcaster.send(JSON.stringify({
                type: 'ice-candidate',
                from: ws.viewerId,
                candidate: data.candidate,
                sdpMid: data.sdpMid,
                sdpMLineIndex: data.sdpMLineIndex
            }));
        }
    }
}

function handleDisconnect(ws) {
    if (ws.isBroadcaster && ws.streamId) {
        console.log(`Broadcaster disconnected: ${ws.streamId}`);
        broadcasters.delete(ws.streamId);

        // Notify all viewers of this stream
        for (const [viewerId, viewer] of viewers.entries()) {
            if (viewer.streamId === ws.streamId && viewer.ws.readyState === 1) {
                viewer.ws.send(JSON.stringify({
                    type: 'broadcaster-left'
                }));
            }
        }
    } else if (ws.viewerId) {
        console.log(`Viewer disconnected: ${ws.viewerId}`);
        viewers.delete(ws.viewerId);

        // Notify broadcaster
        const broadcaster = broadcasters.get(ws.streamId);
        if (broadcaster && broadcaster.readyState === 1) {
            broadcaster.send(JSON.stringify({
                type: 'viewer-left',
                viewer_id: ws.viewerId
            }));
        }
    }
}

// Ping/pong for connection health
setInterval(() => {
    wss.clients.forEach((ws) => {
        if (!ws.isAlive) {
            console.log('Terminating inactive connection');
            return ws.terminate();
        }
        ws.isAlive = false;
        ws.ping();
    });
}, 30000);

// Start server
server.listen(PORT, '0.0.0.0', () => {
    console.log(`
╔════════════════════════════════════════════════════════════╗
║         Pi Camera Signaling Server Started                 ║
╠════════════════════════════════════════════════════════════╣
║  WebSocket: ws://YOUR_SERVER_IP:${PORT}                       ║
║  Web Viewer: http://YOUR_SERVER_IP:${PORT}                    ║
║  Health: http://YOUR_SERVER_IP:${PORT}/health                 ║
╚════════════════════════════════════════════════════════════╝
    `);
});
EOF
```

### 1.4 Create Web Viewer Page

```bash
mkdir -p public
cat > public/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Pi Camera Live Stream</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            min-height: 100vh;
            padding: 20px;
            color: white;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { text-align: center; margin-bottom: 20px; }
        .video-container {
            background: rgba(0,0,0,0.5);
            border-radius: 15px;
            padding: 20px;
            margin-bottom: 20px;
        }
        video {
            width: 100%;
            max-height: 70vh;
            border-radius: 10px;
            background: #000;
        }
        .controls {
            display: flex;
            gap: 10px;
            justify-content: center;
            flex-wrap: wrap;
            margin-top: 15px;
        }
        input {
            padding: 12px 20px;
            font-size: 16px;
            border: none;
            border-radius: 8px;
            min-width: 200px;
        }
        button {
            padding: 12px 30px;
            font-size: 16px;
            border: none;
            border-radius: 8px;
            cursor: pointer;
            transition: transform 0.2s;
        }
        button:hover { transform: translateY(-2px); }
        .btn-connect { background: #4ade80; color: #000; }
        .btn-disconnect { background: #f87171; color: #fff; }
        .status {
            text-align: center;
            padding: 10px;
            margin-top: 15px;
            border-radius: 8px;
            background: rgba(255,255,255,0.1);
        }
        .connected { color: #4ade80; }
        .disconnected { color: #f87171; }
        .connecting { color: #fbbf24; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Pi Camera Live Stream</h1>
        <div class="video-container">
            <video id="video" autoplay playsinline muted></video>
            <div class="controls">
                <input type="text" id="streamId" placeholder="Stream ID" value="pi-camera-stream">
                <button class="btn-connect" id="connectBtn" onclick="connect()">Connect</button>
                <button class="btn-disconnect" id="disconnectBtn" onclick="disconnect()" disabled>Disconnect</button>
            </div>
            <div id="status" class="status disconnected">Disconnected</div>
        </div>
    </div>

    <script>
        let ws = null;
        let pc = null;
        let iceServers = null;

        const video = document.getElementById('video');
        const statusEl = document.getElementById('status');
        const connectBtn = document.getElementById('connectBtn');
        const disconnectBtn = document.getElementById('disconnectBtn');

        function updateStatus(text, className) {
            statusEl.textContent = text;
            statusEl.className = 'status ' + className;
        }

        async function connect() {
            const streamId = document.getElementById('streamId').value.trim();
            if (!streamId) return alert('Enter stream ID');

            updateStatus('Connecting...', 'connecting');
            connectBtn.disabled = true;

            try {
                // Get TURN credentials
                const turnRes = await fetch('/turn-credentials');
                const turnData = await turnRes.json();
                iceServers = turnData.iceServers;

                // Connect WebSocket
                const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
                ws = new WebSocket(`${protocol}//${location.host}`);

                ws.onopen = () => {
                    ws.send(JSON.stringify({ type: 'join', stream_id: streamId }));
                };

                ws.onmessage = async (e) => {
                    const data = JSON.parse(e.data);

                    if (data.type === 'offer') {
                        await handleOffer(data);
                    } else if (data.type === 'ice-candidate') {
                        if (pc) {
                            await pc.addIceCandidate({
                                candidate: data.candidate,
                                sdpMLineIndex: data.sdpMLineIndex
                            });
                        }
                    } else if (data.type === 'broadcaster-left') {
                        updateStatus('Stream ended', 'disconnected');
                        disconnect();
                    }
                };

                ws.onerror = () => {
                    updateStatus('Connection error', 'disconnected');
                    connectBtn.disabled = false;
                };

                ws.onclose = () => {
                    if (statusEl.textContent !== 'Disconnected') {
                        updateStatus('Disconnected', 'disconnected');
                    }
                    connectBtn.disabled = false;
                    disconnectBtn.disabled = true;
                };

            } catch (e) {
                updateStatus('Failed to connect', 'disconnected');
                connectBtn.disabled = false;
            }
        }

        async function handleOffer(data) {
            pc = new RTCPeerConnection({ iceServers });

            pc.ontrack = (e) => {
                if (e.streams[0]) {
                    video.srcObject = e.streams[0];
                    updateStatus('Connected', 'connected');
                    disconnectBtn.disabled = false;
                }
            };

            pc.onicecandidate = (e) => {
                if (e.candidate && ws) {
                    ws.send(JSON.stringify({
                        type: 'ice-candidate',
                        to: data.from,
                        candidate: e.candidate.candidate,
                        sdpMLineIndex: e.candidate.sdpMLineIndex
                    }));
                }
            };

            await pc.setRemoteDescription({ type: 'offer', sdp: data.sdp });
            const answer = await pc.createAnswer();
            await pc.setLocalDescription(answer);

            ws.send(JSON.stringify({
                type: 'answer',
                to: data.from,
                sdp: answer.sdp
            }));
        }

        function disconnect() {
            if (pc) { pc.close(); pc = null; }
            if (ws) { ws.close(); ws = null; }
            if (video.srcObject) {
                video.srcObject.getTracks().forEach(t => t.stop());
                video.srcObject = null;
            }
            updateStatus('Disconnected', 'disconnected');
            connectBtn.disabled = false;
            disconnectBtn.disabled = true;
        }
    </script>
</body>
</html>
HTMLEOF
```

### 1.5 Configure Cloudflare TURN Credentials

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Navigate to **Calls** (left sidebar)
3. Create a new TURN key or use existing
4. Copy your **Turn Key ID** and **API Token**

Create environment file:
```bash
cat > .env << 'EOF'
PORT=8080
CLOUDFLARE_TURN_ID=your_turn_key_id_here
CLOUDFLARE_TURN_TOKEN=your_api_token_here
EOF
```

### 1.6 Install Dependencies and Start

```bash
npm install

# Start with environment variables
source .env && node server.js

# Or for production, use PM2:
sudo npm install -g pm2
pm2 start server.js --name pi-camera-signaling
pm2 save
pm2 startup
```

### 1.7 Open Firewall Ports

**Required Port: 8080 (or your chosen port) - TCP**

#### Check Current Firewall Status

```bash
# UFW (Ubuntu default)
sudo ufw status verbose

# Check if port is in use
sudo netstat -tlnp | grep 8080
# or
sudo ss -tlnp | grep 8080
```

#### Open Port with UFW (Ubuntu)

```bash
# Allow port 8080
sudo ufw allow 8080/tcp comment 'Pi Camera Signaling'

# Reload firewall
sudo ufw reload

# Verify
sudo ufw status
```

#### Open Port with firewalld (CentOS/RHEL)

```bash
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

#### Open Port with iptables

```bash
sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
sudo iptables-save | sudo tee /etc/iptables.rules
```

#### Cloud Provider Security Groups

**IMPORTANT:** If your server is on a cloud provider, you must ALSO open the port in their firewall/security group:

| Provider | Where to Configure |
|----------|-------------------|
| **AWS** | EC2 → Security Groups → Inbound Rules → Add TCP 8080 |
| **GCP** | VPC Network → Firewall → Create Firewall Rule |
| **Azure** | Network Security Group → Inbound security rules |
| **DigitalOcean** | Networking → Firewalls → Add inbound rule |
| **Vultr** | Firewall → Add rule for port 8080 |
| **Linode** | Cloud Firewall → Add inbound rule |

#### Test Port from Outside

```bash
# From another machine, test if port is reachable
nc -zv YOUR_SERVER_IP 8080

# Or with curl
curl -v http://YOUR_SERVER_IP:8080/health

# Expected output if working:
# {"status":"ok","broadcasters":0,"viewers":0}
```

---

## Step 2: Raspberry Pi Setup

### 2.1 Install Dependencies

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install GStreamer and WebRTC dependencies
sudo apt install -y \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-tools \
    gstreamer1.0-nice \
    libnice-dev \
    libsoup2.4-dev \
    libjson-glib-dev \
    libssl-dev \
    cmake \
    build-essential \
    git
```

### 2.2 Clone and Build the Streamer

```bash
# Clone the repository
git clone https://github.com/user/websocket-streaming.git
cd websocket-streaming

# Build
mkdir -p build && cd build
cmake ..
make -j4
```

### 2.3 Configure the Streamer

Create config file:
```bash
cat > ~/stream-config.sh << 'EOF'
#!/bin/bash

# ============== CONFIGURATION ==============
# Replace with your Ubuntu server's IP address
export SIGNALING_SERVER="ws://YOUR_UBUNTU_SERVER_IP:8080"

# Stream identifier
export STREAM_ID="pi-camera-stream"

# Camera settings
export CAMERA_WIDTH=1280
export CAMERA_HEIGHT=720
export CAMERA_FPS=30

# ============================================

cd ~/websocket-streaming/build
./pi_webrtc_streamer \
    --signaling-url "$SIGNALING_SERVER" \
    --stream-id "$STREAM_ID" \
    --width $CAMERA_WIDTH \
    --height $CAMERA_HEIGHT \
    --fps $CAMERA_FPS
EOF

chmod +x ~/stream-config.sh
```

### 2.4 Run the Streamer

```bash
~/stream-config.sh
```

### 2.5 (Optional) Auto-start on Boot

```bash
# Create systemd service
sudo cat > /etc/systemd/system/pi-camera-stream.service << 'EOF'
[Unit]
Description=Pi Camera WebRTC Stream
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
Environment="SIGNALING_SERVER=ws://YOUR_UBUNTU_SERVER_IP:8080"
Environment="STREAM_ID=pi-camera-stream"
WorkingDirectory=/home/pi/websocket-streaming/build
ExecStart=/home/pi/websocket-streaming/build/pi_webrtc_streamer --signaling-url ${SIGNALING_SERVER} --stream-id ${STREAM_ID}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable pi-camera-stream
sudo systemctl start pi-camera-stream

# Check status
sudo systemctl status pi-camera-stream
```

---

## Step 3: View the Stream

### Option A: Web Browser
Open in any browser:
```
http://YOUR_UBUNTU_SERVER_IP:8080
```

### Option B: Flutter App
1. Open the Flutter app
2. Enter: `http://YOUR_UBUNTU_SERVER_IP:8080`
3. Tap "Go"

---

## Quick Reference

### Commands

| Action | Command |
|--------|---------|
| Start signaling (Ubuntu) | `node server.js` |
| Start streamer (Pi) | `~/stream-config.sh` |
| Check signaling status | `curl http://YOUR_SERVER_IP:8080/health` |
| View logs (Pi) | `journalctl -u pi-camera-stream -f` |
| Restart streamer | `sudo systemctl restart pi-camera-stream` |

### Ports

| Port | Service | Protocol |
|------|---------|----------|
| 8080 | Signaling Server | TCP (HTTP/WS) |
| 3478 | TURN (Cloudflare) | UDP/TCP |
| 5349 | TURNS (Cloudflare) | TCP |

### Troubleshooting

**No video?**
- Check Pi camera: `libcamera-hello`
- Check streamer logs: `journalctl -u pi-camera-stream -f`
- Verify signaling: `curl http://YOUR_SERVER_IP:8080/health`

**Connection fails?**
- Check firewall: `sudo ufw status`
- Verify TURN credentials in `.env`
- Check browser console for errors

**High latency?**
- TURN relay adds latency; ensure STUN works first
- Reduce resolution: `--width 640 --height 480`
- Check network bandwidth

---

## Network Diagram

```
Your Network:
┌─────────────────────────────────────────────────────────┐
│                     Internet                             │
│                         │                                │
│         ┌───────────────┴───────────────┐               │
│         │                               │               │
│         ▼                               ▼               │
│  ┌─────────────┐                 ┌─────────────┐        │
│  │ Ubuntu VPS  │                 │  Cloudflare │        │
│  │ (Signaling) │                 │    TURN     │        │
│  │ Public IP   │                 │             │        │
│  └──────┬──────┘                 └──────┬──────┘        │
│         │                               │               │
└─────────┼───────────────────────────────┼───────────────┘
          │ WebSocket                     │ WebRTC Media
          │                               │
    ┌─────┴─────┐                   ┌─────┴─────┐
    │           │                   │           │
    ▼           ▼                   ▼           ▼
┌───────┐  ┌────────┐          ┌───────┐  ┌────────┐
│  Pi   │  │ Viewer │          │  Pi   │  │ Viewer │
│(home) │  │(mobile)│          │       │  │        │
└───────┘  └────────┘          └───────┘  └────────┘
   Signaling only              Media (via TURN if needed)
```

The key advantage: **No domain name or tunnel needed** - just a server with a public IP!
