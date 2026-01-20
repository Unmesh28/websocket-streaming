# WebRTC Reconnection Manual Test Checklist

This checklist verifies the fix for webrtcbin cleanup issues that prevented
reliable reconnections after multiple connect/disconnect cycles.

## Prerequisites

1. Raspberry Pi with camera connected
2. Built streamer binary (`cd build && cmake .. && make`)
3. Signaling server running
4. Browser with WebRTC support

## Test Procedures

### Test 1: Basic Refresh Test (10 cycles)

**Goal**: Verify the streamer handles browser refreshes without getting stuck.

1. [ ] Start the streamer on the Pi
2. [ ] Open browser and connect to the stream
3. [ ] Verify video is streaming
4. [ ] Press F5 to refresh the page
5. [ ] Verify video reconnects and streams
6. [ ] Repeat steps 4-5 at least **10 times**
7. [ ] **Expected Result**: All 10 refreshes should successfully reconnect

**Pass Criteria**:
- ICE connection state reaches "connected" or "completed" each time
- Video displays within 5 seconds of each refresh
- No "GStreamer-CRITICAL" errors in streamer logs
- No segfaults

### Test 2: Disconnect/Connect Button Test

**Goal**: Verify explicit disconnect/connect cycles work correctly.

1. [ ] Start the streamer on the Pi
2. [ ] Open browser and connect to the stream
3. [ ] Click "Disconnect" button
4. [ ] Wait 2-3 seconds
5. [ ] Click "Connect" button
6. [ ] Verify video reconnects
7. [ ] Repeat steps 3-6 at least **10 times**
8. [ ] **Expected Result**: All disconnect/connect cycles should succeed

**Pass Criteria**:
- Clean disconnect without errors
- Reconnect succeeds each time
- No resource leaks (check file descriptors)

### Test 3: Rapid Reconnection Test

**Goal**: Verify handling of rapid connect/disconnect cycles.

1. [ ] Start the streamer on the Pi
2. [ ] Open browser and connect
3. [ ] Immediately refresh (within 1 second of video appearing)
4. [ ] Repeat rapid refresh 5 times
5. [ ] **Expected Result**: All rapid refreshes should succeed

**Pass Criteria**:
- No deadlocks or hangs
- ICE cleanup completes properly
- TURN allocations are released

### Test 4: Multiple Viewers Test

**Goal**: Verify multi-viewer cleanup works correctly.

1. [ ] Start the streamer on the Pi
2. [ ] Open **3 browser tabs/windows** all connected to the stream
3. [ ] Verify all 3 viewers receive video
4. [ ] Close one browser tab
5. [ ] Verify remaining 2 tabs still stream
6. [ ] Open a new browser tab and connect
7. [ ] Verify all 3 tabs stream
8. [ ] Close all tabs one by one
9. [ ] Open a new tab and verify it connects
10. [ ] **Expected Result**: Closing/opening viewers doesn't affect others

**Pass Criteria**:
- Independent viewer lifecycles
- No cross-contamination between viewers
- Clean cleanup of each viewer

### Test 5: Long Duration Stress Test

**Goal**: Verify stability over extended period with multiple cycles.

1. [ ] Start the streamer on the Pi
2. [ ] Note the initial file descriptor count: `ls /proc/<streamer_pid>/fd | wc -l`
3. [ ] Perform 20 connect/disconnect cycles over 10 minutes
4. [ ] Check final file descriptor count
5. [ ] **Expected Result**: FD count should not increase significantly

**Pass Criteria**:
- File descriptor count should not grow more than ~10 over baseline
- No "We still have alive TURN refreshes" warnings after cleanup
- Memory usage stable (check with `ps aux | grep streamer`)

## Checklist Summary

| Test | Pass/Fail | Notes |
|------|-----------|-------|
| Test 1: Basic Refresh (10x) | | |
| Test 2: Disconnect/Connect (10x) | | |
| Test 3: Rapid Reconnection (5x) | | |
| Test 4: Multiple Viewers | | |
| Test 5: Long Duration Stress | | |

## Expected Log Messages

After a successful cleanup, you should see:
```
[PEER] Cleaning up peer: viewer-xxx
[PEER] Disconnecting signal handlers...
[PEER] Adding IDLE probe on video tee pad for safe removal...
[PEER] IDLE probe fired for viewer-xxx - safe to remove elements
[PEER] Performing cleanup operations for: viewer-xxx
[PEER] Unlinking video path...
[PEER] Unlinking audio path...
[PEER] Sending EOS to flush queues...
[PEER] Setting elements to NULL state...
[PEER] Setting webrtcbin to NULL (triggers ICE cleanup)...
[PEER] Releasing request pads...
[PEER] Removing elements from pipeline...
[PEER] Unreferencing elements...
[PEER] Cleanup operations complete for: viewer-xxx
[PEER] Running main loop for TURN cleanup (2000ms)...
[PEER] Main loop cleanup complete
[PEER] Peer cleanup complete: viewer-xxx
```

## Troubleshooting

### If ICE stays at "checking":
- Check Cloudflare TURN credentials are valid
- Verify network allows UDP traffic on TURN ports
- Check for "alive TURN refreshes" warnings in previous cleanup

### If cleanup hangs:
- Check if IDLE probe times out (3 second timeout)
- Look for deadlock warnings in logs
- Verify signal handlers are disconnected before cleanup

### If segfault occurs:
- Check for "GStreamer-CRITICAL" messages before crash
- Verify elements are in NULL state before removal
- Check pad states during cleanup
