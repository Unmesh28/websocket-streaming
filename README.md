# WebRTC Streaming System for Raspberry Pi

Production-ready C++ WebRTC streaming solution for Raspberry Pi with audio and video support.

## 🎯 Features

- ✅ Real-time audio and video streaming from Raspberry Pi
- ✅ WebRTC-based low latency (~300-500ms)
- ✅ Multiple simultaneous viewers (5-10 viewers per stream)
- ✅ Production-optimized C++ code using GStreamer
- ✅ WebSocket signaling server (Node.js)
- ✅ HTML viewer interface
- ✅ ngrok tunneling for remote access
- ✅ Support for USB cameras and Pi Camera
- ✅ H.264 hardware encoding
- ✅ Opus audio encoding

## 📋 Requirements

### Hardware
- Raspberry Pi 4 (recommended) or Pi 3B+
- USB Camera or Raspberry Pi Camera Module
- USB Microphone or audio input device
- MicroSD card (16GB+ recommended)
- Stable internet connection

### Software
- Raspberry Pi OS (Bullseye or newer)
- GCC 7.0 or newer
- CMake 3.10 or newer
- Node.js 14 or newer
- ngrok account (free tier works)

## 🚀 Quick Start Guide

### Step 1: Transfer Files to Raspberry Pi

```bash
# On your computer, extract the zip file
unzip webrtc_pi_streaming.zip
cd webrtc_pi_streaming

# Transfer to Raspberry Pi (replace PI_IP with your Pi's IP)
scp -r webrtc_pi_streaming pi@PI_IP:~/
```

Or use USB drive/SD card to transfer.

### Step 2: SSH into Raspberry Pi

```bash
ssh pi@PI_IP
cd ~/webrtc_pi_streaming
```

### Step 3: Install Dependencies

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Install all dependencies (takes 15-20 minutes)
./scripts/install_dependencies.sh
```

### Step 4: Configure ngrok

```bash
# Sign up at https://ngrok.com (free)
# Get your authtoken from dashboard

# Configure ngrok
ngrok config add-authtoken YOUR_AUTHTOKEN_HERE
```

### Step 5: Build C++ Application

```bash
# Build the project
./scripts/build.sh

# This creates: build/webrtc_streamer
```

### Step 6: Test Camera and Audio

```bash
# List cameras
v4l2-ctl --list-devices

# Test camera (should show video)
gst-launch-1.0 v4l2src device=/dev/video0 ! videoconvert ! autovideosink

# List audio devices
arecord -l

# Test microphone (record 5 seconds and play back)
arecord -d 5 test.wav && aplay test.wav
```

## 🎬 Running the System

### Terminal 1: Start Signaling Server

```bash
cd ~/webrtc_pi_streaming
./scripts/start_signaling.sh
```

You should see:
```
========================================
  WebRTC Signaling Server
========================================
HTTP server: http://localhost:8080
WebSocket:   ws://localhost:8080
========================================
```

### Terminal 2: Start ngrok Tunnel

```bash
# Open new terminal
cd ~/webrtc_pi_streaming
./scripts/start_ngrok.sh
```

You should see:
```
========================================
  ngrok Tunnel Started
========================================
HTTP URL:      https://abc123.ngrok-free.app
WebSocket URL: wss://abc123.ngrok-free.app
========================================
```

**SAVE THIS WEBSOCKET URL!** You'll need it in next steps.

### Terminal 3: Start C++ Streamer

```bash
# Open new terminal
cd ~/webrtc_pi_streaming

# Run with ngrok URL (replace with your actual URL from step above)
./build/webrtc_streamer wss://abc123.ngrok-free.app

# Or with custom parameters:
# ./build/webrtc_streamer <signaling_url> <stream_id> <video_device> <audio_device>
# Example:
# ./build/webrtc_streamer wss://abc123.ngrok-free.app my-stream /dev/video0 default
```

You should see:
```
=====================================
  WebRTC Streamer for Raspberry Pi
=====================================
Signaling: wss://abc123.ngrok-free.app
Stream ID: pi-camera-stream
Video:     /dev/video0
Audio:     default
=====================================

Connecting to signaling server...
Connected to signaling server
Registering as broadcaster: pi-camera-stream

========================================
   STREAMING READY - Waiting for viewers
========================================
```

## 👀 Viewing the Stream

### Option 1: Using HTML Viewer (Recommended)

1. Open browser (Chrome, Firefox, Safari)
2. Go to: `https://abc123.ngrok-free.app` (your ngrok HTTP URL)
3. You'll see the HTML viewer interface
4. The stream ID should be pre-filled as `pi-camera-stream`
5. The server URL should be your ngrok WebSocket URL
6. Click "Connect"
7. Video should start playing!

### Option 2: Open HTML File Directly

1. Download the `web/index.html` file to your computer
2. Open it in a browser
3. Enter:
   - Stream ID: `pi-camera-stream`
   - Server URL: `wss://abc123.ngrok-free.app` (your ngrok WebSocket URL)
4. Click "Connect"

### Multiple Viewers

- Share the ngrok URL with others
- Each person can open the HTML viewer and connect
- Supports 5-10 simultaneous viewers

## 📊 System Architecture

```
┌─────────────────────────────────────┐
│  Raspberry Pi                       │
│  ┌──────────────────────────────┐  │
│  │  Camera + Microphone         │  │
│  └──────────┬───────────────────┘  │
│             │                       │
│  ┌──────────▼───────────────────┐  │
│  │  C++ WebRTC Streamer         │  │
│  │  (GStreamer + webrtcbin)     │  │
│  └──────────┬───────────────────┘  │
│             │                       │
│  ┌──────────▼───────────────────┐  │
│  │  Signaling Server (Node.js)  │  │
│  └──────────┬───────────────────┘  │
└─────────────┼───────────────────────┘
              │
              ▼
         ngrok Tunnel
              │
              ▼
     Public WebSocket URL
              │
      ┌───────┴────────┐
      │                │
  Viewer 1         Viewer 2
  (Browser)        (Browser)
```

## 🔧 Configuration Options

### Changing Video Resolution

Edit `src/webrtc_stream.cpp`, line ~28:

```cpp
"video/x-raw,width=1280,height=720,framerate=30/1 ! "

// Change to:
"video/x-raw,width=640,height=480,framerate=30/1 ! "  // Lower quality
// or
"video/x-raw,width=1920,height=1080,framerate=30/1 ! " // Higher quality
```

Then rebuild: `./scripts/build.sh`

### Changing Audio Bitrate

Edit `src/webrtc_stream.cpp`, line ~48:

```cpp
"opusenc bitrate=32000 ! "

// Change to:
"opusenc bitrate=64000 ! "  // Higher quality
```

### Using Different Camera/Mic

```bash
# List available cameras
v4l2-ctl --list-devices

# List available audio devices
arecord -l

# Run with specific devices
./build/webrtc_streamer wss://YOUR_URL pi-stream /dev/video1 hw:1,0
```

## 🐛 Troubleshooting

### Camera Not Detected

```bash
# Check if camera is connected
v4l2-ctl --list-devices

# For Pi Camera, enable it:
sudo raspi-config
# Interface Options → Camera → Enable

# Reboot
sudo reboot
```

### Audio Not Working

```bash
# Check audio devices
arecord -l

# Test microphone
arecord -d 5 test.wav
aplay test.wav

# If no sound, check volume
alsamixer
```

### C++ Build Fails

```bash
# Make sure all dependencies are installed
./scripts/install_dependencies.sh

# Clean build
rm -rf build
./scripts/build.sh
```

### WebSocket Connection Fails

```bash
# Check signaling server is running
curl http://localhost:8080/status

# Check ngrok is running
curl http://localhost:4040/api/tunnels

# Restart ngrok
./scripts/start_ngrok.sh
```

### High CPU Usage

```bash
# Monitor CPU
htop

# Reduce video quality in src/webrtc_stream.cpp
# Change to 640x480 instead of 1280x720

# Reduce framerate
# Change framerate=30/1 to framerate=15/1
```

### No Video in Browser

1. Check browser console for errors (F12)
2. Make sure using HTTPS/WSS URLs (not HTTP/WS)
3. Try different browser (Chrome recommended)
4. Check firewall/antivirus settings
5. Verify ngrok URL is correct

## 📝 Usage Examples

### Basic Usage

```bash
# Default stream
./build/webrtc_streamer wss://YOUR_NGROK_URL.ngrok-free.app
```

### Custom Stream ID

```bash
# Use custom stream name
./build/webrtc_streamer wss://YOUR_URL my-custom-stream
```

### Different Camera

```bash
# Use specific camera
./build/webrtc_streamer wss://YOUR_URL pi-stream /dev/video1
```

### Full Custom Configuration

```bash
./build/webrtc_streamer \
    wss://abc123.ngrok-free.app \
    vehicle-001 \
    /dev/video1 \
    hw:1,0
```

## 🔐 Security Notes

### For Production Use:

1. **Use HTTPS/WSS** - ngrok provides this automatically
2. **Add authentication** to signaling server
3. **Implement access control** for streams
4. **Use static domain** instead of ngrok random URLs
5. **Rate limit** connections
6. **Monitor** for abuse

### Adding Basic Auth to Signaling Server

Edit `signaling/server.js`:

```javascript
// Add before wss.on('connection')
const VALID_TOKENS = new Set(['your-secret-token']);

wss.on('connection', (ws, req) => {
    const token = req.url.split('?token=')[1];
    
    if (!VALID_TOKENS.has(token)) {
        ws.close(1008, 'Unauthorized');
        return;
    }
    
    // ... rest of code
});
```

## 📈 Performance Tips

1. **Lower resolution** for more viewers (640x480 vs 1280x720)
2. **Reduce framerate** if CPU is high (15fps vs 30fps)
3. **Use h264 hardware encoding** (already enabled)
4. **Close unused applications** on Pi
5. **Use wired ethernet** instead of WiFi
6. **Increase GPU memory**: `sudo raspi-config` → Performance → GPU Memory → 256

## 🆘 Getting Help

### Check Logs

```bash
# C++ app output (in Terminal 3)
# Signaling server output (in Terminal 1)

# Check system logs
journalctl -xe

# Check GStreamer debug
GST_DEBUG=3 ./build/webrtc_streamer wss://YOUR_URL
```

### Common Error Messages

| Error | Solution |
|-------|----------|
| "Failed to connect to signaling server" | Check signaling server is running, verify ngrok URL |
| "Pipeline creation error" | Check camera is connected, verify device path |
| "WebSocket connection failed" | Check ngrok is running, verify using WSS not WS |
| "Failed to initialize stream" | Check camera/microphone permissions |

## 📦 File Structure

```
webrtc_pi_streaming/
├── CMakeLists.txt           # Build configuration
├── README.md                # This file
├── include/                 # Header files
│   ├── webrtc_stream.h
│   └── signaling_client.h
├── src/                     # Source files
│   ├── main.cpp
│   ├── webrtc_stream.cpp
│   └── signaling_client.cpp
├── signaling/               # Signaling server
│   ├── server.js
│   └── package.json
├── web/                     # HTML viewer
│   └── index.html
└── scripts/                 # Helper scripts
    ├── install_dependencies.sh
    ├── build.sh
    ├── start_signaling.sh
    └── start_ngrok.sh
```

## 🎓 Next Steps

1. **Test locally** before deploying
2. **Monitor performance** with multiple viewers
3. **Implement Flutter app** for mobile viewing
4. **Add recording** functionality
5. **Implement call mode** (two-way audio)
6. **Add multiple camera support**
7. **Deploy to all 350 vehicles**

## 📄 License

MIT License - Free to use for commercial projects

## 👨‍💻 Support

For issues or questions, check the troubleshooting section above.

---

**Ready to start streaming!** 🚀
