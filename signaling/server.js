const WebSocket = require('ws');
const http = require('http');
const express = require('express');
const path = require('path');
const crypto = require('crypto');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Cloudflare TURN credentials (same as used by the streamer)
const TURN_KEY_ID = process.env.TURN_KEY_ID || '5765757461f633c76e862dd0f39d2c9191bc46e9084dd8a498730540ac7b7737';
const TURN_API_TOKEN = process.env.TURN_API_TOKEN || 'fa9d64c8fbdd51a8df17e1156b42ccf81c56b23d0e24e1ed353a762a062e614e';

// Generate Cloudflare TURN credentials
function generateTurnCredentials() {
    // Cloudflare TURN uses time-limited credentials
    // Format: username = <expiry_timestamp>:<key_id>
    // password = base64(HMAC-SHA256(<api_token>, <username>))

    const expiryTime = Math.floor(Date.now() / 1000) + 86400; // 24 hours
    const username = `${expiryTime}:${TURN_KEY_ID}`;
    const hmac = crypto.createHmac('sha256', TURN_API_TOKEN);
    hmac.update(username);
    const password = hmac.digest('base64');

    return {
        urls: [
            'turn:turn.cloudflare.com:3478?transport=udp',
            'turn:turn.cloudflare.com:3478?transport=tcp',
            'turns:turn.cloudflare.com:5349?transport=tcp'
        ],
        username: username,
        credential: password
    };
}

// Serve static files (HTML viewer)
app.use(express.static(path.join(__dirname, '../web')));

// Store connections
const broadcasters = new Map(); // streamId -> { ws, viewers: Set }
const viewers = new Map();       // viewerId -> { ws, streamId, broadcasterId, ready: boolean }
const connections = new Map();   // ws -> { clientId, clientRole }

// Buffer for pending offers when viewer isn't ready yet
const pendingOffers = new Map(); // viewerId -> { sdp, timestamp }
const PENDING_OFFER_TIMEOUT = 10000; // 10 seconds

let nextViewerId = 1;

function logStatus() {
    console.log(`[STATUS] Broadcasters: ${broadcasters.size}, Viewers: ${viewers.size}, Connections: ${connections.size}`);
}

wss.on('connection', (ws, req) => {
    const clientIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
    console.log(`[CONNECT] New WebSocket connection from ${clientIp}`);
    logStatus();

    // Store connection info
    connections.set(ws, { clientId: null, clientRole: null });

    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            console.log(`[MESSAGE] Received: ${data.type}`, JSON.stringify(data).substring(0, 200));

            switch(data.type) {
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

                case 'viewer-ready':
                    handleViewerReady(ws, data);
                    break;

                default:
                    console.log(`[WARN] Unknown message type: ${data.type}`);
            }
        } catch (error) {
            console.error(`[ERROR] Error processing message:`, error);
        }
    });

    ws.on('close', (code, reason) => {
        console.log(`[CLOSE] WebSocket closed - code: ${code}, reason: ${reason}`);
        handleDisconnect(ws);
    });

    ws.on('error', (error) => {
        console.error(`[ERROR] WebSocket error:`, error);
    });

    // Ping/pong to keep connection alive
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
});

// Keep-alive ping every 30 seconds
const pingInterval = setInterval(() => {
    wss.clients.forEach((ws) => {
        if (ws.isAlive === false) {
            console.log('[PING] Terminating dead connection');
            return ws.terminate();
        }
        ws.isAlive = false;
        ws.ping();
    });
}, 30000);

// Clean up stale pending offers every 30 seconds
const pendingOfferCleanupInterval = setInterval(() => {
    const now = Date.now();
    for (const [viewerId, offer] of pendingOffers.entries()) {
        if (now - offer.timestamp > PENDING_OFFER_TIMEOUT) {
            console.log(`[CLEANUP] Removing stale pending offer for ${viewerId}`);
            pendingOffers.delete(viewerId);
        }
    }
}, 30000);

wss.on('close', () => {
    clearInterval(pingInterval);
    clearInterval(pendingOfferCleanupInterval);
});

function handleRegister(ws, data) {
    if (data.role === 'broadcaster') {
        const streamId = data.stream_id;

        // Update connection info
        const connInfo = connections.get(ws);
        if (connInfo) {
            connInfo.clientId = streamId;
            connInfo.clientRole = 'broadcaster';
        }

        // Check if broadcaster already exists
        if (broadcasters.has(streamId)) {
            console.log(`[REGISTER] Replacing existing broadcaster for stream: ${streamId}`);
            const old = broadcasters.get(streamId);
            if (old.ws !== ws) {
                // Close old broadcaster connection
                old.ws.close();
            }
        }

        broadcasters.set(streamId, {
            ws: ws,
            viewers: new Set()
        });

        console.log(`[REGISTER] Broadcaster registered: ${streamId}`);
        logStatus();

        ws.send(JSON.stringify({
            type: 'registered',
            stream_id: streamId
        }));
    }
}

function handleJoin(ws, data) {
    const streamId = data.stream_id;

    // Check if this WebSocket already has a viewer - clean up old one first
    const connInfo = connections.get(ws);
    if (connInfo && connInfo.clientRole === 'viewer' && connInfo.clientId) {
        const oldViewerId = connInfo.clientId;
        console.log(`[JOIN] WebSocket already has viewer ${oldViewerId}, cleaning up before rejoin`);

        // Clean up old viewer from previous stream
        const oldViewer = viewers.get(oldViewerId);
        if (oldViewer) {
            const oldBroadcaster = broadcasters.get(oldViewer.broadcasterId);
            if (oldBroadcaster) {
                oldBroadcaster.viewers.delete(oldViewerId);
                try {
                    oldBroadcaster.ws.send(JSON.stringify({
                        type: 'viewer-left',
                        viewer_id: oldViewerId
                    }));
                } catch (e) {
                    // Ignore send errors
                }
            }
            viewers.delete(oldViewerId);
        }
    }

    const viewerId = 'viewer-' + nextViewerId++;

    // Update connection info
    if (connInfo) {
        connInfo.clientId = viewerId;
        connInfo.clientRole = 'viewer';
    }

    const broadcaster = broadcasters.get(streamId);

    if (!broadcaster) {
        console.log(`[JOIN] Stream not found: ${streamId}`);
        ws.send(JSON.stringify({
            type: 'error',
            message: 'Stream not found: ' + streamId
        }));
        return;
    }

    // Check if broadcaster WebSocket is still open
    if (broadcaster.ws.readyState !== WebSocket.OPEN) {
        console.log(`[JOIN] Broadcaster WebSocket not open for stream: ${streamId}`);
        ws.send(JSON.stringify({
            type: 'error',
            message: 'Broadcaster not available'
        }));
        return;
    }

    // Add viewer
    broadcaster.viewers.add(viewerId);
    viewers.set(viewerId, {
        ws: ws,
        streamId: streamId,
        broadcasterId: streamId,
        ready: false  // Will be set to true when viewer sends 'viewer-ready' message
    });

    console.log(`[JOIN] Viewer ${viewerId} joined stream: ${streamId} (total viewers: ${broadcaster.viewers.size})`);
    logStatus();

    // Confirm to viewer first (so they can send viewer-ready)
    ws.send(JSON.stringify({
        type: 'joined',
        viewer_id: viewerId,
        stream_id: streamId
    }));

    // Delay broadcaster notification slightly to allow viewer to send viewer-ready
    // This helps prevent the race condition where offer is sent before viewer is ready
    setTimeout(() => {
        // Re-check viewer is still connected
        const currentViewer = viewers.get(viewerId);
        if (!currentViewer || currentViewer.ws.readyState !== WebSocket.OPEN) {
            console.log(`[JOIN] Viewer ${viewerId} disconnected before broadcaster notification`);
            return;
        }

        // Notify broadcaster
        try {
            broadcaster.ws.send(JSON.stringify({
                type: 'viewer-joined',
                viewer_id: viewerId
            }));
            console.log(`[JOIN] Notified broadcaster about ${viewerId}`);
        } catch (e) {
            console.error(`[JOIN] Failed to notify broadcaster:`, e);
        }
    }, 100); // 100ms delay
}

function handleOffer(ws, data) {
    const viewerId = data.to;
    const viewer = viewers.get(viewerId);

    if (viewer) {
        // Check if viewer WebSocket is still open
        if (viewer.ws.readyState !== WebSocket.OPEN) {
            console.log(`[OFFER] Viewer ${viewerId} WebSocket not open, buffering offer`);
            pendingOffers.set(viewerId, { sdp: data.sdp, timestamp: Date.now() });
            return;
        }

        console.log(`[OFFER] Forwarding offer to ${viewerId} (ready: ${viewer.ready})`);
        try {
            viewer.ws.send(JSON.stringify({
                type: 'offer',
                from: viewer.broadcasterId,
                sdp: data.sdp
            }));
        } catch (e) {
            console.error(`[OFFER] Failed to forward, buffering:`, e);
            pendingOffers.set(viewerId, { sdp: data.sdp, timestamp: Date.now() });
        }
    } else {
        console.log(`[OFFER] Viewer not found: ${viewerId}, buffering offer`);
        pendingOffers.set(viewerId, { sdp: data.sdp, timestamp: Date.now() });
    }
}

function handleViewerReady(ws, data) {
    const connInfo = connections.get(ws);
    if (!connInfo || connInfo.clientRole !== 'viewer') {
        console.log('[VIEWER-READY] Not a viewer connection');
        return;
    }

    const viewerId = connInfo.clientId;
    const viewer = viewers.get(viewerId);

    if (!viewer) {
        console.log(`[VIEWER-READY] Viewer not found: ${viewerId}`);
        return;
    }

    viewer.ready = true;
    console.log(`[VIEWER-READY] Viewer ${viewerId} is ready`);

    // Check if there's a pending offer for this viewer
    const pendingOffer = pendingOffers.get(viewerId);
    if (pendingOffer) {
        console.log(`[VIEWER-READY] Sending buffered offer to ${viewerId}`);
        try {
            viewer.ws.send(JSON.stringify({
                type: 'offer',
                from: viewer.broadcasterId,
                sdp: pendingOffer.sdp
            }));
            pendingOffers.delete(viewerId);
        } catch (e) {
            console.error(`[VIEWER-READY] Failed to send buffered offer:`, e);
        }
    }
}

function handleAnswer(ws, data) {
    const broadcasterId = data.to;
    const broadcaster = broadcasters.get(broadcasterId);

    // Get the viewer's ID from connection info
    const connInfo = connections.get(ws);
    const viewerId = connInfo ? connInfo.clientId : 'unknown';

    if (broadcaster) {
        console.log(`[ANSWER] Forwarding answer from ${viewerId} to broadcaster`);
        try {
            broadcaster.ws.send(JSON.stringify({
                type: 'answer',
                from: viewerId,
                sdp: data.sdp
            }));
        } catch (e) {
            console.error(`[ANSWER] Failed to forward:`, e);
        }
    } else {
        console.log(`[ANSWER] Broadcaster not found: ${broadcasterId}`);
    }
}

function handleIceCandidate(ws, data) {
    const peerId = data.to;
    const connInfo = connections.get(ws);
    const fromId = connInfo ? connInfo.clientId : 'unknown';

    // Check if peer is broadcaster
    const broadcaster = broadcasters.get(peerId);
    if (broadcaster) {
        try {
            broadcaster.ws.send(JSON.stringify({
                type: 'ice-candidate',
                from: fromId,
                candidate: data.candidate,
                sdpMLineIndex: data.sdpMLineIndex
            }));
        } catch (e) {
            console.error(`[ICE] Failed to forward to broadcaster:`, e);
        }
        return;
    }

    // Check if peer is viewer
    const viewer = viewers.get(peerId);
    if (viewer) {
        try {
            viewer.ws.send(JSON.stringify({
                type: 'ice-candidate',
                from: fromId,
                candidate: data.candidate,
                sdpMLineIndex: data.sdpMLineIndex
            }));
        } catch (e) {
            console.error(`[ICE] Failed to forward to viewer:`, e);
        }
    }
}

function handleDisconnect(ws) {
    const connInfo = connections.get(ws);

    if (!connInfo) {
        console.log('[DISCONNECT] Unknown connection');
        connections.delete(ws);
        return;
    }

    const { clientId, clientRole } = connInfo;

    if (clientRole === 'broadcaster' && clientId) {
        const broadcaster = broadcasters.get(clientId);
        if (broadcaster && broadcaster.ws === ws) {
            // Notify all viewers
            console.log(`[DISCONNECT] Broadcaster disconnected: ${clientId}, notifying ${broadcaster.viewers.size} viewers`);
            broadcaster.viewers.forEach(viewerId => {
                const viewer = viewers.get(viewerId);
                if (viewer) {
                    try {
                        viewer.ws.send(JSON.stringify({
                            type: 'broadcaster-left'
                        }));
                    } catch (e) {
                        // Ignore send errors during disconnect
                    }
                    viewers.delete(viewerId);
                }
            });

            broadcasters.delete(clientId);
        }
    } else if (clientRole === 'viewer' && clientId) {
        const viewer = viewers.get(clientId);
        if (viewer) {
            // Notify broadcaster
            const broadcaster = broadcasters.get(viewer.broadcasterId);
            if (broadcaster) {
                broadcaster.viewers.delete(clientId);
                try {
                    broadcaster.ws.send(JSON.stringify({
                        type: 'viewer-left',
                        viewer_id: clientId
                    }));
                } catch (e) {
                    // Ignore send errors during disconnect
                }
                console.log(`[DISCONNECT] Viewer disconnected: ${clientId}, remaining viewers: ${broadcaster.viewers.size}`);
            }

            viewers.delete(clientId);
            pendingOffers.delete(clientId); // Clean up any pending offers
        }
    }

    connections.delete(ws);
    logStatus();
}

const PORT = process.env.PORT || 8080;

server.listen(PORT, () => {
    console.log('\n========================================');
    console.log('  WebRTC Signaling Server (Enhanced)');
    console.log('========================================');
    console.log(`HTTP server: http://localhost:${PORT}`);
    console.log(`WebSocket:   ws://localhost:${PORT}`);
    console.log('========================================\n');
    console.log('Waiting for connections...\n');
});

// Status endpoint
app.get('/status', (req, res) => {
    const status = {
        broadcasters: Array.from(broadcasters.keys()),
        viewerCount: viewers.size,
        connectionCount: connections.size,
        uptime: process.uptime()
    };
    console.log('[STATUS] API request:', status);
    res.json(status);
});

// Health check endpoint
app.get('/health', (req, res) => {
    res.json({ status: 'ok', uptime: process.uptime() });
});

// TURN credentials endpoint - browsers need this for NAT traversal
app.get('/turn-credentials', (req, res) => {
    const creds = generateTurnCredentials();
    console.log('[TURN] Generated credentials for browser client');
    res.json({
        iceServers: [
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun.cloudflare.com:3478' },
            creds
        ]
    });
});

console.log('Starting signaling server...');
