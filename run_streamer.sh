#!/bin/bash
#
# Resilient WebRTC Streamer Runner
# Automatically restarts the streamer on crash with exponential backoff
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STREAMER_BIN="$SCRIPT_DIR/build/webrtc_streamer"
LOG_FILE="/tmp/webrtc_streamer.log"
PID_FILE="/tmp/webrtc_streamer.pid"

# Configuration
MAX_RESTART_DELAY=60      # Maximum delay between restarts (seconds)
INITIAL_RESTART_DELAY=2   # Initial delay between restarts (seconds)
SUCCESS_RESET_TIME=300    # Reset backoff after this many seconds of successful running

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

cleanup() {
    log "Shutting down..."
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null
            wait "$PID" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

# Check if streamer binary exists
if [ ! -f "$STREAMER_BIN" ]; then
    log_error "Streamer binary not found at $STREAMER_BIN"
    log "Please build first: cd $SCRIPT_DIR && mkdir -p build && cd build && cmake .. && make"
    exit 1
fi

# Get signaling server URL from command line or use default
SIGNALING_URL="${1:-}"
if [ -z "$SIGNALING_URL" ]; then
    log_error "Usage: $0 <signaling_server_url>"
    log "Example: $0 wss://your-server.ngrok-free.app"
    exit 1
fi

log "========================================"
log "  Resilient WebRTC Streamer"
log "========================================"
log "Signaling: $SIGNALING_URL"
log "Binary: $STREAMER_BIN"
log "Log: $LOG_FILE"
log "========================================"

restart_delay=$INITIAL_RESTART_DELAY
restart_count=0

while true; do
    start_time=$(date +%s)

    log "Starting streamer (attempt $((restart_count + 1)))..."

    # Run the streamer and capture its PID
    "$STREAMER_BIN" "$SIGNALING_URL" 2>&1 | tee -a "$LOG_FILE" &
    STREAMER_PID=$!
    echo "$STREAMER_PID" > "$PID_FILE"

    # Wait for streamer to exit
    wait "$STREAMER_PID"
    EXIT_CODE=$?

    end_time=$(date +%s)
    run_duration=$((end_time - start_time))

    rm -f "$PID_FILE"

    # Check exit code
    if [ $EXIT_CODE -eq 0 ]; then
        log "Streamer exited normally"
        break
    fi

    restart_count=$((restart_count + 1))

    # Log crash info
    if [ $EXIT_CODE -eq 134 ]; then
        log_error "Streamer crashed with SIGABRT (libnice assertion failure)"
    elif [ $EXIT_CODE -eq 139 ]; then
        log_error "Streamer crashed with SIGSEGV (segmentation fault)"
    elif [ $EXIT_CODE -eq 137 ]; then
        log_error "Streamer was killed (SIGKILL)"
    else
        log_error "Streamer exited with code $EXIT_CODE after ${run_duration}s"
    fi

    # Reset backoff if streamer ran successfully for a while
    if [ $run_duration -ge $SUCCESS_RESET_TIME ]; then
        log "Streamer ran for ${run_duration}s - resetting restart delay"
        restart_delay=$INITIAL_RESTART_DELAY
    fi

    log_warn "Restarting in ${restart_delay}s... (restart #$restart_count)"
    sleep "$restart_delay"

    # Exponential backoff with cap
    restart_delay=$((restart_delay * 2))
    if [ $restart_delay -gt $MAX_RESTART_DELAY ]; then
        restart_delay=$MAX_RESTART_DELAY
    fi
done

log "Streamer runner exiting"
