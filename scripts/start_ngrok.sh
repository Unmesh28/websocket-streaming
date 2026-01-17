#!/bin/bash

echo "Starting ngrok tunnel..."

# Kill any existing ngrok processes
pkill -f ngrok 2>/dev/null
sleep 1

# Start ngrok in background
ngrok http 8080 --log=stdout > /tmp/ngrok.log 2>&1 &
NGROK_PID=$!

# Wait for ngrok to start
echo "Waiting for ngrok to initialize..."
sleep 5

# Check if ngrok is still running
if ! ps -p $NGROK_PID > /dev/null 2>&1; then
    echo "ERROR: ngrok failed to start"
    echo "Check if authtoken is configured: ngrok config add-authtoken YOUR_TOKEN"
    cat /tmp/ngrok.log
    exit 1
fi

# Get the public URL
NGROK_URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"[^"]*' | grep -o 'https://[^"]*' | head -1)

if [ -z "$NGROK_URL" ]; then
    echo "ERROR: Could not get ngrok URL"
    echo "Check ngrok log:"
    cat /tmp/ngrok.log
    exit 1
fi

# Convert to WebSocket URL
WS_URL=$(echo $NGROK_URL | sed 's/https/wss/')

echo ""
echo "=========================================="
echo "  ngrok Tunnel Running (PID: $NGROK_PID)"
echo "=========================================="
echo "HTTP URL:      $NGROK_URL"
echo "WebSocket URL: $WS_URL"
echo ""
echo "Use this WebSocket URL to start streaming:"
echo "  ./build/webrtc_streamer $WS_URL"
echo ""
echo "Open this URL in browser to view stream:"
echo "  $NGROK_URL"
echo "=========================================="
echo ""

# Save URL to file for easy access
echo "$WS_URL" > .ngrok_url
echo "URL saved to .ngrok_url file"
echo ""
echo "Press Ctrl+C to stop ngrok tunnel..."
echo ""

# Keep script running and show ngrok output
tail -f /tmp/ngrok.log
