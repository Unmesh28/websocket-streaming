#include "webrtc_stream.h"
#include "signaling_client.h"
#include <iostream>
#include <signal.h>
#include <map>
#include <memory>
#include <gst/gst.h>

static bool running = true;

void signalHandler(int signum) {
    std::cout << "\nShutting down..." << std::endl;
    running = false;
}

class StreamManager {
public:
    StreamManager(const std::string& signaling_url, const std::string& stream_id)
        : stream_id_(stream_id)
        , signaling_(signaling_url) {
        
        // Setup signaling callbacks
        signaling_.setOnViewerJoined([this](const std::string& viewer_id) {
            onViewerJoined(viewer_id);
        });
        
        signaling_.setOnAnswer([this](const std::string& viewer_id, const std::string& sdp) {
            onAnswer(viewer_id, sdp);
        });
        
        signaling_.setOnIceCandidate([this](const std::string& viewer_id, 
                                            const std::string& candidate, 
                                            int sdp_mline_index) {
            onIceCandidate(viewer_id, candidate, sdp_mline_index);
        });
        
        signaling_.setOnViewerLeft([this](const std::string& viewer_id) {
            onViewerLeft(viewer_id);
        });
    }
    
    bool start(const std::string& video_device = "/dev/video0",
              const std::string& audio_device = "default") {
        
        video_device_ = video_device;
        audio_device_ = audio_device;
        
        // Connect to signaling server
        std::cout << "Connecting to signaling server..." << std::endl;
        if (!signaling_.connect()) {
            std::cerr << "Failed to connect to signaling server" << std::endl;
            return false;
        }
        
        std::cout << "Connected to signaling server" << std::endl;
        
        // Register as broadcaster
        std::cout << "Registering as broadcaster: " << stream_id_ << std::endl;
        signaling_.registerBroadcaster(stream_id_);
        
        std::cout << "\n========================================" << std::endl;
        std::cout << "   STREAMING READY - Waiting for viewers" << std::endl;
        std::cout << "========================================" << std::endl;
        std::cout << "Stream ID: " << stream_id_ << std::endl;
        std::cout << "Video: " << video_device_ << std::endl;
        std::cout << "Audio: " << audio_device_ << std::endl;
        std::cout << "========================================\n" << std::endl;
        
        return true;
    }
    
    void run() {
        // Start GStreamer main loop
        GMainLoop* loop = g_main_loop_new(nullptr, FALSE);
        
        // Run loop in separate thread
        std::thread loop_thread([loop]() {
            g_main_loop_run(loop);
        });
        
        // Wait for shutdown signal
        while (running) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        
        // Stop loop
        g_main_loop_quit(loop);
        loop_thread.join();
        g_main_loop_unref(loop);
    }
    
    void stop() {
        std::cout << "Stopping all streams..." << std::endl;
        
        // Stop all viewer streams
        viewer_streams_.clear();
        
        // Disconnect signaling
        signaling_.disconnect();
        
        std::cout << "All streams stopped" << std::endl;
    }

private:
    std::string stream_id_;
    std::string video_device_;
    std::string audio_device_;
    SignalingClient signaling_;
    std::map<std::string, std::shared_ptr<WebRTCStream>> viewer_streams_;
    
    void onViewerJoined(const std::string& viewer_id) {
        std::cout << "\n[+] Viewer joined: " << viewer_id << std::endl;
        
        // Create new stream for this viewer
        auto stream = std::make_shared<WebRTCStream>(stream_id_ + "-" + viewer_id);
        
        std::cout << "    Initializing stream..." << std::endl;
        if (!stream->initialize(video_device_, audio_device_)) {
            std::cerr << "    [ERROR] Failed to initialize stream" << std::endl;
            return;
        }
        
        // Set ICE candidate callback
        stream->setIceCandidateCallback([this, viewer_id](const std::string& candidate, int sdp_mline_index) {
            signaling_.sendIceCandidate(viewer_id, candidate, sdp_mline_index);
        });
        
        // Start stream
        std::cout << "    Starting stream..." << std::endl;
        if (!stream->start()) {
            std::cerr << "    [ERROR] Failed to start stream" << std::endl;
            return;
        }
        
        // Create and send offer
        std::cout << "    Creating WebRTC offer..." << std::endl;
        stream->createOffer([this, viewer_id](const std::string& sdp) {
            std::cout << "    Sending offer to viewer..." << std::endl;
            signaling_.sendOffer(viewer_id, sdp);
        });
        
        viewer_streams_[viewer_id] = stream;
        
        std::cout << "[✓] Stream established for viewer: " << viewer_id << std::endl;
        std::cout << "    Active viewers: " << viewer_streams_.size() << "\n" << std::endl;
    }
    
    void onAnswer(const std::string& viewer_id, const std::string& sdp) {
        std::cout << "[<] Received answer from: " << viewer_id << std::endl;
        
        auto it = viewer_streams_.find(viewer_id);
        if (it != viewer_streams_.end()) {
            it->second->setRemoteAnswer(sdp);
            std::cout << "[✓] Connection established with: " << viewer_id << "\n" << std::endl;
        }
    }
    
    void onIceCandidate(const std::string& viewer_id, const std::string& candidate, int sdp_mline_index) {
        auto it = viewer_streams_.find(viewer_id);
        if (it != viewer_streams_.end()) {
            it->second->addIceCandidate(candidate, sdp_mline_index);
        }
    }
    
    void onViewerLeft(const std::string& viewer_id) {
        std::cout << "[-] Viewer left: " << viewer_id << std::endl;
        viewer_streams_.erase(viewer_id);
        std::cout << "    Active viewers: " << viewer_streams_.size() << "\n" << std::endl;
    }
};

int main(int argc, char* argv[]) {
    // Handle Ctrl+C
    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);
    
    // Parse arguments
    std::string signaling_url = "ws://localhost:8080"; // Default (will use ngrok)
    std::string stream_id = "pi-camera-stream";
    std::string video_device = "/dev/video0";
    std::string audio_device = "default";
    
    if (argc > 1) signaling_url = argv[1];
    if (argc > 2) stream_id = argv[2];
    if (argc > 3) video_device = argv[3];
    if (argc > 4) audio_device = argv[4];
    
    std::cout << "\n=====================================" << std::endl;
    std::cout << "  WebRTC Streamer for Raspberry Pi" << std::endl;
    std::cout << "=====================================" << std::endl;
    std::cout << "Signaling: " << signaling_url << std::endl;
    std::cout << "Stream ID: " << stream_id << std::endl;
    std::cout << "Video:     " << video_device << std::endl;
    std::cout << "Audio:     " << audio_device << std::endl;
    std::cout << "=====================================\n" << std::endl;
    
    // Create and start stream manager
    StreamManager manager(signaling_url, stream_id);
    
    if (!manager.start(video_device, audio_device)) {
        return 1;
    }
    
    // Run
    manager.run();
    
    // Cleanup
    manager.stop();
    
    std::cout << "\nGoodbye!\n" << std::endl;
    return 0;
}
