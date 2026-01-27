#ifndef SHARED_MEDIA_PIPELINE_H
#define SHARED_MEDIA_PIPELINE_H

#include <gst/gst.h>
#include <string>
#include <map>
#include <mutex>
#include <functional>
#include <vector>
#include <atomic>

// Forward declaration
class WebRTCPeer;

class SharedMediaPipeline {
public:
    // Camera types
    enum class CameraType {
        CSI,         // Raspberry Pi Camera Module (CSI interface) - uses libcamerasrc (modern)
        LEGACY_CSI,  // Raspberry Pi Camera Module (legacy) - uses rpicamsrc (old camera stack)
        USB          // USB Webcam - uses v4l2src
    };

    SharedMediaPipeline();
    ~SharedMediaPipeline();

    // Initialize the shared pipeline with camera and audio
    bool initialize(const std::string& video_device = "/dev/video0",
                   const std::string& audio_device = "default",
                   CameraType camera_type = CameraType::CSI);

    // Start the pipeline
    bool start();

    // Stop the pipeline
    void stop();

    // Add a new viewer - returns a WebRTCPeer that handles the WebRTC connection
    WebRTCPeer* addViewer(const std::string& viewer_id);

    // Remove a viewer
    void removeViewer(const std::string& viewer_id);

    // Get pipeline for debugging
    GstElement* getPipeline() const { return pipeline_; }

    // Check if running
    bool isRunning() const { return is_running_; }

    // Force a keyframe (called when new viewer joins)
    void forceKeyframe();

private:
    GstElement* pipeline_;
    GstElement* video_tee_;
    GstElement* audio_tee_;
    GstElement* video_encoder_;
    bool is_running_;
    std::mutex mutex_;

    std::map<std::string, WebRTCPeer*> viewers_;

    // Create the shared capture/encode pipeline
    bool createPipeline(const std::string& video_device,
                       const std::string& audio_device,
                       CameraType camera_type);
};

// WebRTC peer connection for a single viewer
class WebRTCPeer {
public:
    // TURN server configuration
    struct TurnConfig {
        std::string uri;        // e.g., "turn:turn.example.com:3478"
        std::string username;
        std::string password;
    };

    WebRTCPeer(const std::string& viewer_id, GstElement* pipeline,
               GstElement* video_tee, GstElement* audio_tee);
    ~WebRTCPeer();

    // Initialize the webrtcbin
    bool initialize();

    // Set TURN server (must be called before initialize())
    static void setTurnServer(const TurnConfig& config);

    // Enable Cloudflare TURN (dynamic credentials)
    static void enableCloudflareTurn();

    // Check if using Cloudflare TURN
    static bool isUsingCloudflareTurn();

    // Create offer for WebRTC negotiation
    void createOffer(std::function<void(const std::string&)> callback);

    // Handle remote answer
    void setRemoteAnswer(const std::string& sdp);

    // Handle ICE candidate (queues if remote description not set)
    void addIceCandidate(const std::string& candidate, int sdp_mline_index);

    // Process queued ICE candidates (called after remote description is set)
    void processQueuedIceCandidates();

    // Set callback for ICE candidates
    void setIceCandidateCallback(std::function<void(const std::string&, int)> callback);

    // Get viewer ID
    std::string getViewerId() const { return viewer_id_; }

    // Cleanup - unlink from tees (safe to call multiple times)
    void cleanup();

private:
    std::string viewer_id_;
    GstElement* pipeline_;          // Parent pipeline (not owned)
    GstElement* video_tee_;         // Video tee (not owned)
    GstElement* audio_tee_;         // Audio tee (not owned)
    GstElement* webrtcbin_;         // Our webrtcbin (owned)
    GstElement* video_queue_;       // Queue before webrtcbin (owned)
    GstElement* audio_queue_;       // Queue before webrtcbin (owned)
    GstPad* video_tee_pad_;         // Our pad on video tee
    GstPad* audio_tee_pad_;         // Our pad on audio tee
    GstPad* webrtc_video_sink_;     // Sink pad on webrtcbin for video
    GstPad* webrtc_audio_sink_;     // Sink pad on webrtcbin for audio

    // Probe IDs for cleanup
    gulong video_tee_probe_id_;
    gulong video_queue_sink_probe_id_;
    gulong video_queue_src_probe_id_;

    bool cleaned_up_;               // Prevent double cleanup
    std::atomic<int> cleanup_removing_;  // Atomic guard for probe callback (0=not removing, 1=removing)
    std::mutex cleanup_mutex_;      // Thread safety for cleanup

    // Cleanup context for IDLE probe pattern
    struct CleanupContext {
        WebRTCPeer* peer;
        bool is_video;  // true for video path, false for audio path
        GCond cond;
        GMutex mutex;
        bool done;
    };

    // Helper methods for cleanup
    void doCleanupInProbe(bool is_video);
    static GstPadProbeReturn cleanupIdleProbeCallback(GstPad* pad, GstPadProbeInfo* info, gpointer user_data);

    // ICE candidate queuing to prevent libnice crashes
    struct IceCandidate {
        std::string candidate;
        int sdp_mline_index;
    };
    std::vector<IceCandidate> queued_ice_candidates_;
    std::atomic<bool> remote_description_set_;
    std::mutex ice_mutex_;          // Thread safety for ICE operations

    std::function<void(const std::string&, int)> ice_candidate_callback_;
    std::function<void(const std::string&)> offer_callback_;

    // Static TURN server config (shared by all peers)
    static TurnConfig turn_config_;
    static bool turn_configured_;
    static bool use_cloudflare_turn_;

    // Global mutex for ICE operations to prevent libnice race conditions
    // libnice has internal state that can crash when multiple peers
    // process ICE candidates simultaneously
    static std::mutex global_ice_mutex_;

    // GStreamer callbacks
    static void onNegotiationNeeded(GstElement* webrtc, gpointer user_data);
    static void onIceCandidate(GstElement* webrtc, guint mlineindex,
                              gchar* candidate, gpointer user_data);
    static void onOfferCreated(GstPromise* promise, gpointer user_data);
    static void onIceConnectionStateChange(GstElement* webrtc, GParamSpec* pspec, gpointer user_data);
    static void onConnectionStateChange(GstElement* webrtc, GParamSpec* pspec, gpointer user_data);
    static void onIceGatheringStateChange(GstElement* webrtc, GParamSpec* pspec, gpointer user_data);
};

#endif // SHARED_MEDIA_PIPELINE_H
