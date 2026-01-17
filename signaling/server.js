const WebSocket = require('ws');
const http = require('http');
const express = require('express');
const path = require('path');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Serve static files (HTML viewer)
app.use(express.static(path.join(__dirname, '../web')));

// Store connections
const broadcasters = new Map(); // streamId -> { ws, viewers: Set }
const viewers = new Map();       // viewerId -> { ws, streamId, broadcasterId }

let nextViewerId = 1;

wss.on('connection', (ws) => {
    console.log('New WebSocket connection');
    
    let clientId = null;
    let clientRole = null;
    
    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            console.log('Received:', data.type, data);
            
            switch(data.type) {
                case 'register':
                    handleRegister(ws, data);
                    break;
                    
                case 'join':
                    handleJoin(ws, data);
                    break;
                    
                case 'offer':
                    handleOffer(data);
                    break;
                    
                case 'answer':
                    handleAnswer(data);
                    break;
                    
                case 'ice-candidate':
                    handleIceCandidate(data);
                    break;
                    
                default:
                    console.log('Unknown message type:', data.type);
            }
        } catch (error) {
            console.error('Error processing message:', error);
        }
    });
    
    ws.on('close', () => {
        console.log('WebSocket connection closed');
        handleDisconnect(ws);
    });
    
    ws.on('error', (error) => {
        console.error('WebSocket error:', error);
    });
    
    function handleRegister(ws, data) {
        if (data.role === 'broadcaster') {
            const streamId = data.stream_id;
            clientId = streamId;
            clientRole = 'broadcaster';
            
            broadcasters.set(streamId, {
                ws: ws,
                viewers: new Set()
            });
            
            console.log(`Broadcaster registered: ${streamId}`);
            
            ws.send(JSON.stringify({
                type: 'registered',
                stream_id: streamId
            }));
        }
    }
    
    function handleJoin(ws, data) {
        const streamId = data.stream_id;
        const viewerId = 'viewer-' + nextViewerId++;
        
        clientId = viewerId;
        clientRole = 'viewer';
        
        const broadcaster = broadcasters.get(streamId);
        
        if (!broadcaster) {
            ws.send(JSON.stringify({
                type: 'error',
                message: 'Stream not found'
            }));
            return;
        }
        
        // Add viewer
        broadcaster.viewers.add(viewerId);
        viewers.set(viewerId, {
            ws: ws,
            streamId: streamId,
            broadcasterId: streamId
        });
        
        console.log(`Viewer ${viewerId} joined stream: ${streamId}`);
        
        // Notify broadcaster
        broadcaster.ws.send(JSON.stringify({
            type: 'viewer-joined',
            viewer_id: viewerId
        }));
        
        // Confirm to viewer
        ws.send(JSON.stringify({
            type: 'joined',
            viewer_id: viewerId,
            stream_id: streamId
        }));
    }
    
    function handleOffer(data) {
        const viewerId = data.to;
        const viewer = viewers.get(viewerId);
        
        if (viewer) {
            console.log(`Forwarding offer to ${viewerId}`);
            viewer.ws.send(JSON.stringify({
                type: 'offer',
                from: viewer.broadcasterId,
                sdp: data.sdp
            }));
        }
    }
    
    function handleAnswer(data) {
        const broadcasterId = data.to;
        const broadcaster = broadcasters.get(broadcasterId);
        
        if (broadcaster) {
            console.log(`Forwarding answer to broadcaster`);
            broadcaster.ws.send(JSON.stringify({
                type: 'answer',
                from: clientId,
                sdp: data.sdp
            }));
        }
    }
    
    function handleIceCandidate(data) {
        const peerId = data.to;
        
        // Check if peer is broadcaster
        const broadcaster = broadcasters.get(peerId);
        if (broadcaster) {
            broadcaster.ws.send(JSON.stringify({
                type: 'ice-candidate',
                from: clientId,
                candidate: data.candidate,
                sdpMLineIndex: data.sdpMLineIndex
            }));
            return;
        }
        
        // Check if peer is viewer
        const viewer = viewers.get(peerId);
        if (viewer) {
            viewer.ws.send(JSON.stringify({
                type: 'ice-candidate',
                from: clientId,
                candidate: data.candidate,
                sdpMLineIndex: data.sdpMLineIndex
            }));
        }
    }
    
    function handleDisconnect(ws) {
        if (clientRole === 'broadcaster' && clientId) {
            const broadcaster = broadcasters.get(clientId);
            if (broadcaster) {
                // Notify all viewers
                broadcaster.viewers.forEach(viewerId => {
                    const viewer = viewers.get(viewerId);
                    if (viewer) {
                        viewer.ws.send(JSON.stringify({
                            type: 'broadcaster-left'
                        }));
                        viewers.delete(viewerId);
                    }
                });
                
                broadcasters.delete(clientId);
                console.log(`Broadcaster disconnected: ${clientId}`);
            }
        } else if (clientRole === 'viewer' && clientId) {
            const viewer = viewers.get(clientId);
            if (viewer) {
                // Notify broadcaster
                const broadcaster = broadcasters.get(viewer.broadcasterId);
                if (broadcaster) {
                    broadcaster.viewers.delete(clientId);
                    broadcaster.ws.send(JSON.stringify({
                        type: 'viewer-left',
                        viewer_id: clientId
                    }));
                }
                
                viewers.delete(clientId);
                console.log(`Viewer disconnected: ${clientId}`);
            }
        }
    }
});

const PORT = process.env.PORT || 8080;

server.listen(PORT, () => {
    console.log('\n========================================');
    console.log('  WebRTC Signaling Server');
    console.log('========================================');
    console.log(`HTTP server: http://localhost:${PORT}`);
    console.log(`WebSocket:   ws://localhost:${PORT}`);
    console.log('========================================\n');
    console.log('Waiting for connections...\n');
});

// Status endpoint
app.get('/status', (req, res) => {
    res.json({
        broadcasters: Array.from(broadcasters.keys()),
        viewers: viewers.size,
        uptime: process.uptime()
    });
});

console.log('Starting signaling server...');
