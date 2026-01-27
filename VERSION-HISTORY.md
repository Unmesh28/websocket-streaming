# Version History

## v1.0-working-baseline (2026-01-27) - VERIFIED WORKING ✅

**Status:** Fully tested and confirmed working

**Commit:** `07f87c5` - Fix video streaming by sending H264 codec config with every keyframe

### What Works:
- ✅ **Camera:** Raspberry Pi CSI Camera (OV5647 5MP IR Night Vision)
- ✅ **Video:** H.264 encoding at 1280x720@30fps
- ✅ **Audio:** Opus encoding from Pi microphone (48kHz mono)
- ✅ **Streaming:** WebRTC from Pi to web browser
- ✅ **Multi-viewer:** Multiple browsers can view simultaneously
- ✅ **Network:** STUN/TURN support for NAT traversal
- ✅ **Browser:** Video displays correctly with proper dimensions

### Hardware Tested:
- Raspberry Pi (with CSI camera interface)
- OV5647 5MP IR Night Vision Camera Module
- ALSA audio input device

### Key Configuration:
```cpp
// Critical setting for late-joining viewers:
h264parse config-interval=1     // Send SPS/PPS with every keyframe
rtph264pay config-interval=1    // Include codec config in RTP packets
```

### Key Fixes Applied:
1. **WebSocket TLS Fix:** Switched from `asio_tls_client` to `asio_client` for plain WebSocket
2. **Server Binding:** Changed from localhost to 0.0.0.0 for external access
3. **CORS Support:** Added CORS headers for cross-origin requests
4. **Codec Config:** Changed config-interval from -1 to 1 for proper H.264 streaming

### Verified Behavior:
```
[PROBE] Video buffers at tee: 100              ✓ Camera capturing
[PROBE] Buffers at tee src for viewer-1: 100   ✓ Buffer distribution
[PROBE] Buffers entering queue for viewer-1: 100 ✓ Queue working
[PROBE] Buffers reaching webrtcbin...           ✓ WebRTC transmission

Browser Console:
[WEBRTC] Connection state: connected            ✓ Peer connected
[VIDEO-STATE] Dimensions: 1280x720              ✓ Video decoding
[VIDEO-STATE] readyState: 4                     ✓ Playing
```

### Known Limitations:
- One-way streaming only (Pi → Browser)
- No browser microphone input to Pi
- No recording functionality

### Restore Instructions:
```bash
# Restore from tag:
git checkout v1.0-working-baseline

# Or restore from backup branch:
git checkout claude/backup-working-v1.0

# Or restore specific commit:
git checkout 07f87c5
```

### Next Steps:
- Add bidirectional audio (browser mic → Pi)
- Add recording functionality
- Add stream controls (resolution, framerate)

---

## Development Branches:
- `claude/working-commit-YPWng` - Main working branch
- `claude/backup-working-v1.0` - Backup of this working version
- `claude/switch-commit-branch-YPWng` - Earlier experimental branch

---

**⚠️ IMPORTANT:** This version is confirmed working. Before making changes, always create a new branch from this checkpoint.
