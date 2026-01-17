#!/bin/bash

echo "Starting ngrok tunnel..."

# Kill any existing ngrok processes
pkill -f ngrok

# Start ngrok
ngrok http 8080 > /dev/null 2>&1 &

# Wait for ngrok to start
sleep 3

# Get the public URL
echo ""
echo "=========================================="
echo "  ngrok Tunnel Started"
echo "=========================================="

NGROK_URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"[^"]*' | grep -o 'https://[^"]*' | head -1)

if [ -z "$NGROK_URL" ]; then
    echo "ERROR: Could not get ngrok URL"
    echo "Make sure ngrok is configured with authtoken"
    exit 1
fi

# Convert to WebSocket URL
WS_URL=$(echo $NGROK_URL | sed 's/https/wss/')

echo "HTTP URL:      $NGROK_URL"
echo "WebSocket URL: $WS_URL"
echo ""
echo "Use this URL in:"
echo "1. C++ app:    ./build/webrtc_streamer $WS_URL"
echo "2. HTML viewer: Open browser and enter $WS_URL"
echo "=========================================="
echo ""

# Save URL to file for easy access
echo "$WS_URL" > .ngrok_url
echo "URL saved to .ngrok_url file"
