#include "shared_media_pipeline.h"
#include "signaling_client.h"
#include "cloudflare_turn.h"
#include <iostream>
#include <signal.h>
#include <map>
#include <memory>
#include <cstdlib>
#include <gst/gst.h>

static bool running = true;

void signalHandler(int signum) {
    std::cout << "\nShutting down..." << std::endl;
    running = false;
}

class StreamManager {
public:
    StreamManager(const std::string& signaling_url, const std::string& stream_id,
                  SharedMediaPipeline::CameraType camera_type = SharedMediaPipeline::CameraType::CSI)
        : stream_id_(stream_id)
        , signaling_(signaling_url)
        , camera_type_(camera_type) {

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

        // Initialize shared media pipeline FIRST (captures camera once)
        std::cout << "Initializing shared media pipeline..." << std::endl;
        if (!shared_pipeline_.initialize(video_device_, audio_device_, camera_type_)) {
            std::cerr << "Failed to initialize shared media pipeline" << std::endl;
            return false;
        }

        // Start the shared pipeline
        std::cout << "Starting shared media pipeline..." << std::endl;
        if (!shared_pipeline_.start()) {
            std::cerr << "Failed to start shared media pipeline" << std::endl;
            return false;
        }

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
        std::cout << "Multi-viewer: ENABLED (shared pipeline)" << std::endl;
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

        // Stop shared pipeline (this will cleanup all viewers)
        shared_pipeline_.stop();

        // Clear peer map
        viewer_peers_.clear();

        // Disconnect signaling
        signaling_.disconnect();

        std::cout << "All streams stopped" << std::endl;
    }

private:
    std::string stream_id_;
    std::string video_device_;
    std::string audio_device_;
    SharedMediaPipeline::CameraType camera_type_;
    SignalingClient signaling_;
    SharedMediaPipeline shared_pipeline_;
    std::map<std::string, WebRTCPeer*> viewer_peers_;

    void onViewerJoined(const std::string& viewer_id) {
        std::cout << "\n[+] Viewer joined: " << viewer_id << std::endl;

        // Add viewer to shared pipeline (creates webrtcbin for this viewer)
        std::cout << "    Creating WebRTC peer connection..." << std::endl;
        WebRTCPeer* peer = shared_pipeline_.addViewer(viewer_id);

        if (!peer) {
            std::cerr << "    [ERROR] Failed to create peer for viewer" << std::endl;
            return;
        }

        // Set ICE candidate callback
        peer->setIceCandidateCallback([this, viewer_id](const std::string& candidate, int sdp_mline_index) {
            signaling_.sendIceCandidate(viewer_id, candidate, sdp_mline_index);
        });

        // Create and send offer
        std::cout << "    Creating WebRTC offer..." << std::endl;
        peer->createOffer([this, viewer_id](const std::string& sdp) {
            std::cout << "    Sending offer to viewer..." << std::endl;
            signaling_.sendOffer(viewer_id, sdp);
        });

        viewer_peers_[viewer_id] = peer;

        std::cout << "[OK] Peer connection established for: " << viewer_id << std::endl;
        std::cout << "    Active viewers: " << viewer_peers_.size() << "\n" << std::endl;
    }

    void onAnswer(const std::string& viewer_id, const std::string& sdp) {
        std::cout << "[<] Received answer from: " << viewer_id << std::endl;

        auto it = viewer_peers_.find(viewer_id);
        if (it != viewer_peers_.end()) {
            it->second->setRemoteAnswer(sdp);

            // Force a keyframe so the new viewer can start decoding
            std::cout << "    Forcing keyframe for new viewer..." << std::endl;
            shared_pipeline_.forceKeyframe();

            std::cout << "[OK] Connection established with: " << viewer_id << "\n" << std::endl;
        }
    }

    void onIceCandidate(const std::string& viewer_id, const std::string& candidate, int sdp_mline_index) {
        auto it = viewer_peers_.find(viewer_id);
        if (it != viewer_peers_.end()) {
            it->second->addIceCandidate(candidate, sdp_mline_index);
        }
    }

    void onViewerLeft(const std::string& viewer_id) {
        std::cout << "[-] Viewer left: " << viewer_id << std::endl;

        // Remove from shared pipeline
        shared_pipeline_.removeViewer(viewer_id);
        viewer_peers_.erase(viewer_id);

        std::cout << "    Active viewers: " << viewer_peers_.size() << "\n" << std::endl;
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
    std::string camera_type_str = "csi";  // Default to CSI for Pi Camera Module

    // Show usage if help requested
    if (argc > 1 && (std::string(argv[1]) == "-h" || std::string(argv[1]) == "--help")) {
        std::cout << "Usage: " << argv[0] << " [signaling_url] [stream_id] [video_device] [audio_device] [camera_type]" << std::endl;
        std::cout << "\nCamera types:" << std::endl;
        std::cout << "  csi    - Modern Pi Camera (libcamera) - default" << std::endl;
        std::cout << "  legacy - Legacy Pi Camera (rpicamsrc) - for old Raspberry Pi OS" << std::endl;
        std::cout << "  usb    - USB webcam (v4l2)" << std::endl;
        std::cout << "\nExample:" << std::endl;
        std::cout << "  " << argv[0] << " ws://3.110.83.74:8080 pi-camera-stream /dev/video0 default legacy" << std::endl;
        return 0;
    }

    if (argc > 1) signaling_url = argv[1];
    if (argc > 2) stream_id = argv[2];
    if (argc > 3) video_device = argv[3];
    if (argc > 4) audio_device = argv[4];
    if (argc > 5) camera_type_str = argv[5];

    // Parse camera type
    SharedMediaPipeline::CameraType camera_type = SharedMediaPipeline::CameraType::CSI;
    if (camera_type_str == "usb" || camera_type_str == "USB") {
        camera_type = SharedMediaPipeline::CameraType::USB;
    } else if (camera_type_str == "legacy" || camera_type_str == "LEGACY") {
        camera_type = SharedMediaPipeline::CameraType::LEGACY_CSI;
    }

    std::string camera_display;
    if (camera_type == SharedMediaPipeline::CameraType::CSI) {
        camera_display = "CSI (Pi Camera Module - libcamera)";
    } else if (camera_type == SharedMediaPipeline::CameraType::LEGACY_CSI) {
        camera_display = "CSI (Pi Camera Module - legacy)";
    } else {
        camera_display = "USB (" + video_device + ")";
    }

    // Check for TURN server configuration
    // Priority: 1. Cloudflare TURN (dynamic credentials)
    //           2. Static TURN server from environment
    std::string turn_display = "Not configured";

    // Try Cloudflare TURN first (from .env file or environment)
    if (CloudflareTurn::instance().loadConfigFromEnv()) {
        // Test fetching credentials to validate configuration
        auto creds = CloudflareTurn::instance().getCredentials();
        if (creds.valid) {
            WebRTCPeer::enableCloudflareTurn();
            turn_display = "Cloudflare TURN (dynamic credentials)";
        } else {
            std::cerr << "Warning: Cloudflare TURN configured but failed to fetch credentials" << std::endl;
        }
    }

    // Fallback to static TURN server from environment if Cloudflare not configured
    if (!WebRTCPeer::isUsingCloudflareTurn()) {
        const char* turn_uri_env = std::getenv("TURN_SERVER");
        const char* turn_user_env = std::getenv("TURN_USERNAME");
        const char* turn_pass_env = std::getenv("TURN_PASSWORD");

        if (turn_uri_env && turn_uri_env[0]) {
            WebRTCPeer::TurnConfig turn_config;
            turn_config.uri = turn_uri_env;
            if (turn_user_env) turn_config.username = turn_user_env;
            if (turn_pass_env) turn_config.password = turn_pass_env;
            WebRTCPeer::setTurnServer(turn_config);
            turn_display = turn_config.uri;
        }
    }

    std::cout << "\n=====================================" << std::endl;
    std::cout << "  WebRTC Streamer for Raspberry Pi" << std::endl;
    std::cout << "  (Multi-Viewer Support Enabled)" << std::endl;
    std::cout << "=====================================" << std::endl;
    std::cout << "Signaling: " << signaling_url << std::endl;
    std::cout << "Stream ID: " << stream_id << std::endl;
    std::cout << "Camera:    " << camera_display << std::endl;
    std::cout << "Audio:     " << audio_device << std::endl;
    std::cout << "TURN:      " << turn_display << std::endl;
    if (turn_display == "Not configured") {
        std::cout << "           (Set TURN_SERVER, TURN_USERNAME, TURN_PASSWORD env vars for NAT traversal)" << std::endl;
    }
    std::cout << "=====================================\n" << std::endl;

    // Create and start stream manager
    StreamManager manager(signaling_url, stream_id, camera_type);

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
