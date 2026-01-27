#!/bin/bash

# Add GStreamer debugging to see why webrtcbin isn't consuming data

echo "Running streamer with detailed GStreamer debugging..."
echo "This will show WebRTC negotiation details"
echo ""

export GST_DEBUG="3,webrtc*:5,sdp*:5"
export GST_DEBUG_FILE="/tmp/gst-debug.log"

# Run your streamer
./streamer "$@"

echo ""
echo "GStreamer debug log saved to: /tmp/gst-debug.log"
echo "Check for SDP negotiation issues"
