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

// Configuration
const CONFIG = {
    OFFER_TIMEOUT_MS: 30000,      // Timeout for offer/answer exchange
    CLEANUP_DELAY_MS: 100,        // Small delay after cleanup before allowing new joins
    PING_INTERVAL_MS: 30000,      // WebSocket ping interval
    MAX_VIEWERS_PER_STREAM: 50,   // Max viewers per broadcaster
};

// Generate Cloudflare TURN credentials
function generateTurnCredentials() {
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
// Try multiple paths to handle different deployment scenarios
const fs = require('fs');
const possibleWebPaths = [
    path.join(__dirname, 'public'),           // public folder next to server.js
    path.join(process.cwd(), 'public'),       // public in cwd
    '/home/ubuntu/public',                    // Ubuntu deployment path
    path.join(__dirname, '../web'),           // Relative to script (dev)
    path.join(process.cwd(), '../web'),       // Relative to cwd (signaling dir)
    path.join(process.cwd(), 'web'),          // Relative to cwd (project root)
    '/home/user/websocket-streaming/web'      // Absolute fallback
];

const webPath = possibleWebPaths.find(p => {
    try {
        return fs.existsSync(path.join(p, 'index.html'));
    } catch (e) {
        return false;
    }
}) || possibleWebPaths[0];

console.log(`[CONFIG] Serving static files from: ${webPath}`);
app.use(express.static(webPath));

// Explicit route handler for root path
app.get('/', (req, res) => {
    const indexPath = path.join(webPath, 'index.html');
    res.sendFile(indexPath, (err) => {
        if (err) {
            console.error(`[ERROR] Failed to serve index.html: ${err.message}`);
            res.status(500).send('Error loading page. Check server logs.');
        }
    });
});

// ============================================================================
// DATA STRUCTURES
// ============================================================================

const broadcasters = new Map();  // streamId -> { ws, viewers: Set, cleanupQueue: [] }
const viewers = new Map();       // viewerId -> { ws, streamId, broadcasterId, joinedAt, offerSequence }
const connections = new Map();   // ws -> { clientId, clientRole, createdAt }
const pendingOffers = new Map(); // viewerId -> { sequence, timestamp, timeout }

let nextViewerId = 1;
let offerSequence = 1;

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

function logStatus() {
    const broadcasterCount = broadcasters.size;
    const viewerCount = viewers.size;
    const connCount = connections.size;
    const pendingOfferCount = pendingOffers.size;
    console.log(`[STATUS] Broadcasters: ${broadcasterCount}, Viewers: ${viewerCount}, Connections: ${connCount}${pendingOfferCount > 0 ? ', Pending offers: ' + pendingOfferCount : ''}`);
}

// Safe send with WebSocket state verification
function safeSend(ws, message, context = '') {
    if (!ws) {
        console.log(`[SEND-FAIL] ${context}: WebSocket is null`);
        return false;
    }
    if (ws.readyState !== WebSocket.OPEN) {
        console.log(`[SEND-FAIL] ${context}: WebSocket not OPEN (state: ${ws.readyState})`);
        return false;
    }
    try {
        const msgStr = typeof message === 'string' ? message : JSON.stringify(message);
        ws.send(msgStr);
        return true;
    } catch (e) {
        console.error(`[SEND-ERROR] ${context}:`, e.message);
        return false;
    }
}

// Get viewer safely with validation
function getViewerSafe(viewerId) {
    const viewer = viewers.get(viewerId);
    if (!viewer) return null;
    if (!viewer.ws || viewer.ws.readyState !== WebSocket.OPEN) {
        console.log(`[WARN] Viewer ${viewerId} has stale WebSocket, cleaning up`);
        viewers.delete(viewerId);
        return null;
    }
    return viewer;
}

// Get broadcaster safely with validation
function getBroadcasterSafe(streamId) {
    const broadcaster = broadcasters.get(streamId);
    if (!broadcaster) return null;
    if (!broadcaster.ws || broadcaster.ws.readyState !== WebSocket.OPEN) {
        console.log(`[WARN] Broadcaster ${streamId} has stale WebSocket, cleaning up`);
        broadcasters.delete(streamId);
        return null;
    }
    return broadcaster;
}

// Clean up pending offer for a viewer
function cleanupPendingOffer(viewerId) {
    const pending = pendingOffers.get(viewerId);
    if (pending) {
        clearTimeout(pending.timeout);
        pendingOffers.delete(viewerId);
        console.log(`[OFFER] Cleaned up pending offer for ${viewerId}`);
    }
}

// Remove viewer from all data structures atomically
function removeViewerAtomic(viewerId, notifyBroadcaster = true) {
    console.log(`[CLEANUP] Atomic removal of viewer: ${viewerId}`);

    // 1. Cancel pending offer
    cleanupPendingOffer(viewerId);

    // 2. Get viewer data before removal
    const viewer = viewers.get(viewerId);
    if (!viewer) {
        console.log(`[CLEANUP] Viewer ${viewerId} not found, nothing to remove`);
        return false;
    }

    // 3. Remove from broadcaster's viewer set
    const broadcaster = broadcasters.get(viewer.broadcasterId);
    if (broadcaster) {
        broadcaster.viewers.delete(viewerId);

        // 4. Notify broadcaster if requested and still connected
        if (notifyBroadcaster && broadcaster.ws.readyState === WebSocket.OPEN) {
            safeSend(broadcaster.ws, {
                type: 'viewer-left',
                viewer_id: viewerId
            }, `viewer-left for ${viewerId}`);
        }
    }

    // 5. Remove from viewers map
    viewers.delete(viewerId);

    console.log(`[CLEANUP] Viewer ${viewerId} removed successfully`);
    return true;
}

// ============================================================================
// WEBSOCKET CONNECTION HANDLING
// ============================================================================

wss.on('connection', (ws, req) => {
    const clientIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
    console.log(`[CONNECT] New WebSocket connection from ${clientIp}`);

    // Store connection info
    connections.set(ws, {
        clientId: null,
        clientRole: null,
        createdAt: Date.now()
    });

    logStatus();

    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            const msgPreview = JSON.stringify(data).substring(0, 150);
            console.log(`[MESSAGE] ${data.type}${data.to ? ' to=' + data.to : ''}${data.from ? ' from=' + data.from : ''}`);

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
                case 'ping':
                    safeSend(ws, { type: 'pong' }, 'pong');
                    break;
                case 'cleanup-ack':
                    handleCleanupAck(ws, data);
                    break;
                default:
                    console.log(`[WARN] Unknown message type: ${data.type}`);
            }
        } catch (error) {
            console.error(`[ERROR] Error processing message:`, error.message);
        }
    });

    ws.on('close', (code, reason) => {
        console.log(`[CLOSE] WebSocket closed - code: ${code}, reason: ${reason || 'none'}`);
        handleDisconnect(ws);
    });

    ws.on('error', (error) => {
        console.error(`[ERROR] WebSocket error:`, error.message);
    });

    // Ping/pong to keep connection alive
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
});

// Keep-alive ping
const pingInterval = setInterval(() => {
    wss.clients.forEach((ws) => {
        if (ws.isAlive === false) {
            console.log('[PING] Terminating dead connection');
            return ws.terminate();
        }
        ws.isAlive = false;
        ws.ping();
    });
}, CONFIG.PING_INTERVAL_MS);

wss.on('close', () => {
    clearInterval(pingInterval);
});

// ============================================================================
// MESSAGE HANDLERS
// ============================================================================

function handleRegister(ws, data) {
    if (data.role !== 'broadcaster') {
        console.log(`[REGISTER] Invalid role: ${data.role}`);
        return;
    }

    const streamId = data.stream_id;
    if (!streamId) {
        console.log(`[REGISTER] Missing stream_id`);
        return;
    }

    // Update connection info
    const connInfo = connections.get(ws);
    if (connInfo) {
        connInfo.clientId = streamId;
        connInfo.clientRole = 'broadcaster';
    }

    // Check if broadcaster already exists
    const existing = broadcasters.get(streamId);
    if (existing) {
        console.log(`[REGISTER] Replacing existing broadcaster for stream: ${streamId}`);
        if (existing.ws !== ws && existing.ws.readyState === WebSocket.OPEN) {
            // Close old broadcaster connection
            existing.ws.close(1000, 'Replaced by new broadcaster');
        }
        // Clean up existing viewers
        existing.viewers.forEach(viewerId => {
            const viewer = viewers.get(viewerId);
            if (viewer) {
                safeSend(viewer.ws, { type: 'broadcaster-left' }, 'broadcaster-left');
                viewers.delete(viewerId);
            }
            cleanupPendingOffer(viewerId);
        });
    }

    broadcasters.set(streamId, {
        ws: ws,
        viewers: new Set(),
        cleanupQueue: []
    });

    console.log(`[REGISTER] Broadcaster registered: ${streamId}`);
    logStatus();

    safeSend(ws, {
        type: 'registered',
        stream_id: streamId
    }, 'registered');
}

function handleJoin(ws, data) {
    const streamId = data.stream_id;
    if (!streamId) {
        safeSend(ws, { type: 'error', message: 'Missing stream_id' }, 'error');
        return;
    }

    const connInfo = connections.get(ws);
    if (!connInfo) {
        console.log(`[JOIN] Unknown connection`);
        return;
    }

    // Check if this connection already has a viewer - clean up old one FIRST
    if (connInfo.clientRole === 'viewer' && connInfo.clientId) {
        const oldViewerId = connInfo.clientId;
        console.log(`[JOIN] Connection already has viewer ${oldViewerId}, performing atomic cleanup`);

        // Atomic removal - this clears pending offers, removes from maps, notifies broadcaster
        removeViewerAtomic(oldViewerId, true);

        // Send cleanup-complete to client so it knows cleanup is done
        safeSend(ws, {
            type: 'cleanup-complete',
            old_viewer_id: oldViewerId
        }, 'cleanup-complete');
    }

    // Validate broadcaster exists and is available
    const broadcaster = getBroadcasterSafe(streamId);
    if (!broadcaster) {
        console.log(`[JOIN] Stream not found or unavailable: ${streamId}`);
        safeSend(ws, {
            type: 'error',
            message: 'Stream not found: ' + streamId
        }, 'error');
        return;
    }

    // Check viewer limit
    if (broadcaster.viewers.size >= CONFIG.MAX_VIEWERS_PER_STREAM) {
        console.log(`[JOIN] Stream ${streamId} at max capacity (${CONFIG.MAX_VIEWERS_PER_STREAM})`);
        safeSend(ws, {
            type: 'error',
            message: 'Stream at maximum capacity'
        }, 'error');
        return;
    }

    // Create new viewer
    const viewerId = 'viewer-' + nextViewerId++;

    // Update connection info
    connInfo.clientId = viewerId;
    connInfo.clientRole = 'viewer';

    // Add viewer to data structures
    broadcaster.viewers.add(viewerId);
    viewers.set(viewerId, {
        ws: ws,
        streamId: streamId,
        broadcasterId: streamId,
        joinedAt: Date.now(),
        offerSequence: null
    });

    console.log(`[JOIN] Viewer ${viewerId} joined stream: ${streamId} (total viewers: ${broadcaster.viewers.size})`);
    logStatus();

    // Confirm to viewer immediately with their ID
    safeSend(ws, {
        type: 'joined',
        viewer_id: viewerId,
        stream_id: streamId
    }, 'joined');

    // Notify broadcaster - no arbitrary delay, just send immediately
    // The broadcaster (Pi) should handle queuing internally if needed
    safeSend(broadcaster.ws, {
        type: 'viewer-joined',
        viewer_id: viewerId
    }, `viewer-joined ${viewerId}`);
}

function handleOffer(ws, data) {
    const viewerId = data.to;
    if (!viewerId) {
        console.log(`[OFFER] Missing viewer ID`);
        return;
    }

    const viewer = getViewerSafe(viewerId);
    if (!viewer) {
        console.log(`[OFFER] Viewer not found or disconnected: ${viewerId}`);
        return;
    }

    // Generate sequence number for this offer
    const sequence = offerSequence++;

    // Set up offer timeout
    const timeoutId = setTimeout(() => {
        console.log(`[OFFER-TIMEOUT] No answer received for ${viewerId} (seq: ${sequence}) after ${CONFIG.OFFER_TIMEOUT_MS}ms`);
        pendingOffers.delete(viewerId);

        // Notify broadcaster that offer timed out
        const connInfo = connections.get(ws);
        if (connInfo && connInfo.clientRole === 'broadcaster') {
            const broadcaster = getBroadcasterSafe(connInfo.clientId);
            if (broadcaster) {
                safeSend(broadcaster.ws, {
                    type: 'offer-timeout',
                    viewer_id: viewerId,
                    sequence: sequence
                }, 'offer-timeout');
            }
        }
    }, CONFIG.OFFER_TIMEOUT_MS);

    // Track pending offer
    pendingOffers.set(viewerId, {
        sequence: sequence,
        timestamp: Date.now(),
        timeout: timeoutId
    });

    // Store sequence in viewer for answer correlation
    viewer.offerSequence = sequence;

    console.log(`[OFFER] Forwarding offer to ${viewerId} (seq: ${sequence})`);

    const sent = safeSend(viewer.ws, {
        type: 'offer',
        from: viewer.broadcasterId,
        sdp: data.sdp,
        sequence: sequence
    }, `offer to ${viewerId}`);

    if (!sent) {
        // Failed to send offer, clean up
        cleanupPendingOffer(viewerId);
        console.log(`[OFFER] Failed to send offer to ${viewerId}, viewer may have disconnected`);
    }
}

function handleAnswer(ws, data) {
    const broadcasterId = data.to;
    if (!broadcasterId) {
        console.log(`[ANSWER] Missing broadcaster ID`);
        return;
    }

    const broadcaster = getBroadcasterSafe(broadcasterId);
    if (!broadcaster) {
        console.log(`[ANSWER] Broadcaster not found: ${broadcasterId}`);
        return;
    }

    // Get viewer info from connection
    const connInfo = connections.get(ws);
    const viewerId = connInfo ? connInfo.clientId : 'unknown';

    // Clear pending offer timeout
    cleanupPendingOffer(viewerId);

    // Get sequence from viewer for correlation
    const viewer = viewers.get(viewerId);
    const sequence = viewer ? viewer.offerSequence : null;

    console.log(`[ANSWER] Forwarding answer from ${viewerId} to broadcaster (seq: ${sequence})`);

    safeSend(broadcaster.ws, {
        type: 'answer',
        from: viewerId,
        sdp: data.sdp,
        sequence: sequence
    }, `answer from ${viewerId}`);
}

function handleIceCandidate(ws, data) {
    const peerId = data.to;
    if (!peerId) {
        console.log(`[ICE] Missing peer ID`);
        return;
    }

    const connInfo = connections.get(ws);
    const fromId = connInfo ? connInfo.clientId : 'unknown';

    // Check if peer is broadcaster
    const broadcaster = getBroadcasterSafe(peerId);
    if (broadcaster) {
        safeSend(broadcaster.ws, {
            type: 'ice-candidate',
            from: fromId,
            candidate: data.candidate,
            sdpMLineIndex: data.sdpMLineIndex
        }, `ICE to broadcaster from ${fromId}`);
        return;
    }

    // Check if peer is viewer
    const viewer = getViewerSafe(peerId);
    if (viewer) {
        safeSend(viewer.ws, {
            type: 'ice-candidate',
            from: fromId,
            candidate: data.candidate,
            sdpMLineIndex: data.sdpMLineIndex
        }, `ICE to ${peerId} from ${fromId}`);
    } else {
        console.log(`[ICE] Peer not found: ${peerId}`);
    }
}

function handleCleanupAck(ws, data) {
    // Broadcaster acknowledges cleanup of a viewer
    const viewerId = data.viewer_id;
    console.log(`[CLEANUP-ACK] Broadcaster confirmed cleanup of ${viewerId}`);

    // This can be used for additional coordination if needed
    // For now, just log it
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
            console.log(`[DISCONNECT] Broadcaster disconnected: ${clientId}, notifying ${broadcaster.viewers.size} viewers`);

            // Notify all viewers and clean them up
            broadcaster.viewers.forEach(viewerId => {
                const viewer = viewers.get(viewerId);
                if (viewer) {
                    safeSend(viewer.ws, { type: 'broadcaster-left' }, 'broadcaster-left');
                    viewers.delete(viewerId);
                }
                cleanupPendingOffer(viewerId);
            });

            broadcasters.delete(clientId);
        }
    } else if (clientRole === 'viewer' && clientId) {
        console.log(`[DISCONNECT] Viewer disconnected: ${clientId}`);

        // Atomic cleanup - removes from all structures and notifies broadcaster
        removeViewerAtomic(clientId, true);
    }

    connections.delete(ws);
    logStatus();
}

// ============================================================================
// HTTP ENDPOINTS
// ============================================================================

const PORT = process.env.PORT || 8080;

server.listen(PORT, () => {
    console.log('\n========================================');
    console.log('  Pi Camera Signaling Server');
    console.log('========================================');
    console.log(`HTTP:      http://0.0.0.0:${PORT}`);
    console.log(`WebSocket: ws://0.0.0.0:${PORT}`);
    console.log('========================================\n');
});

// Status endpoint with detailed info
app.get('/status', (req, res) => {
    const status = {
        broadcasters: Array.from(broadcasters.entries()).map(([id, b]) => ({
            id,
            viewers: b.viewers.size,
            wsOpen: b.ws.readyState === WebSocket.OPEN
        })),
        viewerCount: viewers.size,
        connectionCount: connections.size,
        pendingOffers: pendingOffers.size,
        uptime: process.uptime()
    };
    console.log('[STATUS] API request');
    res.json(status);
});

// Health check endpoint
app.get('/health', (req, res) => {
    res.json({ status: 'ok', uptime: process.uptime() });
});

// Metrics endpoint for debugging
app.get('/metrics', (req, res) => {
    const metrics = {
        broadcasters: broadcasters.size,
        viewers: viewers.size,
        connections: connections.size,
        pendingOffers: pendingOffers.size,
        memoryUsage: process.memoryUsage(),
        uptime: process.uptime(),
        timestamp: Date.now()
    };
    res.json(metrics);
});

// TURN credentials endpoint
app.get('/turn-credentials', (req, res) => {
    const creds = generateTurnCredentials();
    console.log('[TURN] Generated credentials for client');
    res.json({
        iceServers: [
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun.cloudflare.com:3478' },
            creds
        ]
    });
});

console.log('Starting signaling server...');
