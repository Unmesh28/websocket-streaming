#include "shared_media_pipeline.h"
#include "cloudflare_turn.h"
#include <gst/sdp/sdp.h>
#include <gst/webrtc/webrtc.h>
#include <gst/video/video.h>
#include <iostream>
#include <chrono>
#include <iomanip>
#include <sstream>
#include <map>
#include <cstring>

// ==================== DEBUG LOGGING ====================
#define DEBUG_LOGGING 1

static std::string getTimestamp() {
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    std::stringstream ss;
    ss << std::put_time(std::localtime(&time), "%H:%M:%S")
       << "." << std::setfill('0') << std::setw(3) << ms.count();
    return ss.str();
}

#if DEBUG_LOGGING
#define LOG(category, msg) \
    std::cout << "[" << getTimestamp() << "] [" << category << "] " << msg << std::endl
#define LOG_VAR(category, msg, var) \
    std::cout << "[" << getTimestamp() << "] [" << category << "] " << msg << var << std::endl
#else
#define LOG(category, msg)
#define LOG_VAR(category, msg, var)
#endif

// Buffer counting for debug
static guint64 video_buffer_count = 0;
static guint64 audio_buffer_count = 0;

// Pad probe callback to count buffers at tee
static GstPadProbeReturn tee_buffer_probe(GstPad* pad, GstPadProbeInfo* info, gpointer user_data) {
    const char* media_type = (const char*)user_data;
    if (strcmp(media_type, "video") == 0) {
        video_buffer_count++;
        if (video_buffer_count % 100 == 0) {
            LOG("PROBE", "Video buffers at tee: " << video_buffer_count);
        }
    } else {
        audio_buffer_count++;
        if (audio_buffer_count % 100 == 0) {
            LOG("PROBE", "Audio buffers at tee: " << audio_buffer_count);
        }
    }
    return GST_PAD_PROBE_OK;
}

// Bus message callback for pipeline monitoring
static gboolean bus_callback(GstBus* bus, GstMessage* msg, gpointer user_data) {
    SharedMediaPipeline* pipeline = static_cast<SharedMediaPipeline*>(user_data);

    switch (GST_MESSAGE_TYPE(msg)) {
        case GST_MESSAGE_ERROR: {
            GError* err;
            gchar* debug;
            gst_message_parse_error(msg, &err, &debug);
            LOG_VAR("GST-ERROR", "Error: ", err->message);
            LOG_VAR("GST-ERROR", "Debug: ", debug);
            g_error_free(err);
            g_free(debug);
            break;
        }
        case GST_MESSAGE_WARNING: {
            GError* err;
            gchar* debug;
            gst_message_parse_warning(msg, &err, &debug);
            LOG_VAR("GST-WARN", "Warning: ", err->message);
            g_error_free(err);
            g_free(debug);
            break;
        }
        case GST_MESSAGE_STATE_CHANGED: {
            if (GST_MESSAGE_SRC(msg) == GST_OBJECT(pipeline->getPipeline())) {
                GstState old_state, new_state, pending;
                gst_message_parse_state_changed(msg, &old_state, &new_state, &pending);
                LOG("GST-STATE", "Pipeline state: " <<
                    gst_element_state_get_name(old_state) << " -> " <<
                    gst_element_state_get_name(new_state));
            }
            break;
        }
        case GST_MESSAGE_LATENCY: {
            LOG("GST-LATENCY", "Latency message received, recalculating...");
            gst_bin_recalculate_latency(GST_BIN(pipeline->getPipeline()));
            break;
        }
        default:
            break;
    }
    return TRUE;
}

// ==================== SharedMediaPipeline Implementation ====================

SharedMediaPipeline::SharedMediaPipeline()
    : pipeline_(nullptr)
    , video_tee_(nullptr)
    , audio_tee_(nullptr)
    , video_encoder_(nullptr)
    , is_running_(false) {
    LOG("SHARED", "SharedMediaPipeline created");
}

SharedMediaPipeline::~SharedMediaPipeline() {
    LOG("SHARED", "SharedMediaPipeline destroying");
    stop();
}

bool SharedMediaPipeline::initialize(const std::string& video_device,
                                     const std::string& audio_device,
                                     CameraType camera_type) {
    LOG("SHARED", "Initializing GStreamer...");
    gst_init(nullptr, nullptr);

    LOG_VAR("SHARED", "Video device: ", video_device);
    LOG_VAR("SHARED", "Audio device: ", audio_device);
    LOG_VAR("SHARED", "Camera type: ", (camera_type == CameraType::CSI ? "CSI" : "USB"));

    return createPipeline(video_device, audio_device, camera_type);
}

bool SharedMediaPipeline::createPipeline(const std::string& video_device,
                                         const std::string& audio_device,
                                         CameraType camera_type) {
    GError* error = nullptr;

    // Build video source based on camera type
    std::string video_source;

    if (camera_type == CameraType::CSI) {
        LOG("SHARED", "Using CSI camera (libcamerasrc) - Pi Camera Module");
        video_source =
            "libcamerasrc ! "
            "video/x-raw,width=1280,height=720,framerate=30/1,format=NV12 ! "
            "videoconvert ! "
            "video/x-raw,format=I420 ! ";
    } else {
        LOG_VAR("SHARED", "Using USB camera (v4l2src) - device: ", video_device);
        video_source =
            "v4l2src device=" + video_device + " ! "
            "video/x-raw,width=1280,height=720,framerate=30/1 ! "
            "videoconvert ! "
            "queue max-size-buffers=3 leaky=downstream ! ";
    }

    // Create pipeline with tee elements for multi-viewer support
    // The video and audio are encoded once and distributed via tee elements
    // IMPORTANT: Use fakesink on each tee to ensure data flows even with no viewers
    std::string pipeline_str =
        // Video capture and encoding (shared)
        video_source +
        "x264enc name=video_encoder tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=30 bframes=0 ! "
        "video/x-h264,profile=constrained-baseline ! "
        "h264parse config-interval=-1 ! "
        "rtph264pay config-interval=-1 pt=96 aggregate-mode=zero-latency ! "
        "application/x-rtp,media=video,encoding-name=H264,payload=96 ! "
        "tee name=video_tee allow-not-linked=true "
        // Add a fakesink branch to ensure data always flows
        "video_tee. ! queue ! fakesink async=false sync=false "

        // Audio capture and encoding (shared)
        "alsasrc device=" + audio_device + " ! "
        "audioconvert ! "
        "audioresample ! "
        "audio/x-raw,rate=48000,channels=1 ! "
        "queue max-size-buffers=3 leaky=downstream ! "
        "opusenc bitrate=32000 ! "
        "rtpopuspay pt=97 ! "
        "application/x-rtp,media=audio,encoding-name=OPUS,payload=97 ! "
        "tee name=audio_tee allow-not-linked=true "
        // Add a fakesink branch to ensure data always flows
        "audio_tee. ! queue ! fakesink async=false sync=false";

    LOG("SHARED", "Creating shared pipeline...");
    LOG("SHARED", "Pipeline: " << pipeline_str.substr(0, 400) << "...");

    pipeline_ = gst_parse_launch(pipeline_str.c_str(), &error);

    if (error) {
        LOG_VAR("SHARED-ERROR", "Pipeline creation error: ", error->message);
        g_error_free(error);
        return false;
    }

    // Add bus watch
    GstBus* bus = gst_element_get_bus(pipeline_);
    gst_bus_add_watch(bus, bus_callback, this);
    gst_object_unref(bus);

    // Get tee elements
    video_tee_ = gst_bin_get_by_name(GST_BIN(pipeline_), "video_tee");
    audio_tee_ = gst_bin_get_by_name(GST_BIN(pipeline_), "audio_tee");

    if (!video_tee_ || !audio_tee_) {
        LOG("SHARED-ERROR", "Failed to get tee elements");
        gst_object_unref(pipeline_);
        return false;
    }

    // Get video encoder for forcing keyframes
    video_encoder_ = gst_bin_get_by_name(GST_BIN(pipeline_), "video_encoder");
    if (!video_encoder_) {
        LOG("SHARED-WARN", "Could not get video encoder (keyframe forcing disabled)");
    } else {
        LOG("SHARED", "Got video encoder for keyframe control");
    }

    // Add debug probes on tee sink pads to verify data is flowing
    GstPad* video_tee_sink = gst_element_get_static_pad(video_tee_, "sink");
    if (video_tee_sink) {
        gst_pad_add_probe(video_tee_sink, GST_PAD_PROBE_TYPE_BUFFER,
                         tee_buffer_probe, (gpointer)"video", nullptr);
        gst_object_unref(video_tee_sink);
        LOG("SHARED", "Added video buffer probe on tee sink");
    }

    GstPad* audio_tee_sink = gst_element_get_static_pad(audio_tee_, "sink");
    if (audio_tee_sink) {
        gst_pad_add_probe(audio_tee_sink, GST_PAD_PROBE_TYPE_BUFFER,
                         tee_buffer_probe, (gpointer)"audio", nullptr);
        gst_object_unref(audio_tee_sink);
        LOG("SHARED", "Added audio buffer probe on tee sink");
    }

    LOG("SHARED", "Shared pipeline created successfully with tee elements");
    return true;
}

void SharedMediaPipeline::forceKeyframe() {
    // Method 1: Send force-key-unit event directly to the encoder element
    // gst_element_send_event() handles event direction properly
    if (!video_encoder_) {
        LOG("SHARED", "Cannot force keyframe - no encoder reference");
        return;
    }

    LOG("SHARED", "Forcing keyframe via encoder element...");

    // Create upstream force-key-unit event
    GstEvent* event = gst_video_event_new_upstream_force_key_unit(
        GST_CLOCK_TIME_NONE,  // running_time
        TRUE,                  // all_headers - include SPS/PPS
        0                      // count
    );

    // Send event to encoder - gst_element_send_event handles direction
    gboolean result = gst_element_send_event(video_encoder_, event);
    if (result) {
        LOG("SHARED", "Keyframe request sent successfully to encoder");
    } else {
        LOG("SHARED-WARN", "Encoder rejected keyframe request, trying property method...");

        // Method 2: Fallback - set key-int-max to 1 briefly to force immediate keyframe
        // Then restore it back
        guint current_key_int;
        g_object_get(video_encoder_, "key-int-max", &current_key_int, nullptr);
        g_object_set(video_encoder_, "key-int-max", 1, nullptr);

        // Schedule restoration after a short delay (next frame)
        g_timeout_add(100, [](gpointer data) -> gboolean {
            GstElement* encoder = (GstElement*)data;
            g_object_set(encoder, "key-int-max", 30, nullptr);
            LOG("SHARED", "Restored key-int-max to 30");
            return FALSE;  // Don't repeat
        }, video_encoder_);

        LOG("SHARED", "Forced keyframe via key-int-max property");
    }
}

bool SharedMediaPipeline::start() {
    if (is_running_) {
        LOG("SHARED", "Pipeline already running");
        return true;
    }

    LOG("SHARED", "Starting shared pipeline...");
    GstStateChangeReturn ret = gst_element_set_state(pipeline_, GST_STATE_PLAYING);

    if (ret == GST_STATE_CHANGE_FAILURE) {
        LOG("SHARED-ERROR", "Failed to start pipeline");
        return false;
    }

    is_running_ = true;
    LOG("SHARED", "Shared pipeline started");
    return true;
}

void SharedMediaPipeline::stop() {
    std::lock_guard<std::mutex> lock(mutex_);

    if (!is_running_) {
        return;
    }

    LOG("SHARED", "Stopping shared pipeline...");

    // Remove all viewers
    for (auto& pair : viewers_) {
        pair.second->cleanup();
        delete pair.second;
    }
    viewers_.clear();

    if (pipeline_) {
        gst_element_set_state(pipeline_, GST_STATE_NULL);
        gst_object_unref(pipeline_);
        pipeline_ = nullptr;
    }

    is_running_ = false;
    LOG("SHARED", "Shared pipeline stopped");
}

WebRTCPeer* SharedMediaPipeline::addViewer(const std::string& viewer_id) {
    LOG_VAR("SHARED", ">>> addViewer called for: ", viewer_id);
    LOG("SHARED", "Current viewer count before add: " << viewers_.size());

    std::lock_guard<std::mutex> lock(mutex_);
    LOG("SHARED", "Acquired mutex for viewer: " << viewer_id);

    // Check if viewer already exists
    auto it = viewers_.find(viewer_id);
    if (it != viewers_.end()) {
        LOG_VAR("SHARED-WARN", "Viewer already exists, returning existing: ", viewer_id);
        return it->second;
    }

    // Log current tee state for debugging
    if (video_tee_) {
        GstState tee_state;
        gst_element_get_state(video_tee_, &tee_state, nullptr, GST_SECOND);
        LOG("SHARED", "Video tee state: " << gst_element_state_get_name(tee_state));
    }

    // Create new peer
    LOG("SHARED", "Creating new WebRTCPeer for: " << viewer_id);
    WebRTCPeer* peer = new WebRTCPeer(viewer_id, pipeline_, video_tee_, audio_tee_);

    LOG("SHARED", "Calling peer->initialize() for: " << viewer_id);
    if (!peer->initialize()) {
        LOG_VAR("SHARED-ERROR", "Failed to initialize peer: ", viewer_id);
        delete peer;
        return nullptr;
    }

    viewers_[viewer_id] = peer;
    LOG("SHARED", "<<< Viewer added successfully: " << viewer_id << ", Total viewers: " << viewers_.size());

    return peer;
}

void SharedMediaPipeline::removeViewer(const std::string& viewer_id) {
    LOG_VAR("SHARED", ">>> removeViewer called for: ", viewer_id);

    std::lock_guard<std::mutex> lock(mutex_);
    LOG("SHARED", "Acquired mutex for removing: " << viewer_id);

    auto it = viewers_.find(viewer_id);
    if (it != viewers_.end()) {
        LOG("SHARED", "Found viewer to remove, calling delete...");
        // Delete will call destructor which calls cleanup()
        // No need to call cleanup() explicitly - prevents race conditions
        delete it->second;
        viewers_.erase(it);
        LOG("SHARED", "<<< Viewer removed: " << viewer_id << ", Remaining viewers: " << viewers_.size());
    } else {
        LOG_VAR("SHARED-WARN", "Viewer not found in map: ", viewer_id);
    }
}

// ==================== WebRTCPeer Implementation ====================

// Probe to track buffers at tee src pad (per-viewer)
static GstPadProbeReturn tee_src_probe(GstPad* pad, GstPadProbeInfo* info, gpointer user_data) {
    const char* viewer_id = (const char*)user_data;
    static std::map<std::string, guint64> tee_src_counts;
    tee_src_counts[viewer_id]++;
    if (tee_src_counts[viewer_id] % 100 == 0) {
        LOG("PROBE", "Buffers at tee src for " << viewer_id << ": " << tee_src_counts[viewer_id]);
    }
    return GST_PAD_PROBE_OK;
}

// Probe to track buffers entering queue
static GstPadProbeReturn queue_sink_probe(GstPad* pad, GstPadProbeInfo* info, gpointer user_data) {
    const char* viewer_id = (const char*)user_data;
    static std::map<std::string, guint64> queue_sink_counts;
    queue_sink_counts[viewer_id]++;
    if (queue_sink_counts[viewer_id] % 100 == 0) {
        LOG("PROBE", "Buffers entering queue for " << viewer_id << ": " << queue_sink_counts[viewer_id]);
    }
    return GST_PAD_PROBE_OK;
}

// Buffer probe to count buffers reaching webrtcbin
static GstPadProbeReturn webrtc_buffer_probe(GstPad* pad, GstPadProbeInfo* info, gpointer user_data) {
    const char* viewer_id = (const char*)user_data;
    static std::map<std::string, guint64> webrtc_counts;
    webrtc_counts[viewer_id]++;
    if (webrtc_counts[viewer_id] % 100 == 0) {
        LOG("PROBE", "Buffers reaching webrtcbin for " << viewer_id << ": " << webrtc_counts[viewer_id]);
    }
    return GST_PAD_PROBE_OK;
}

// Static TURN configuration
WebRTCPeer::TurnConfig WebRTCPeer::turn_config_;
bool WebRTCPeer::turn_configured_ = false;
bool WebRTCPeer::use_cloudflare_turn_ = false;

void WebRTCPeer::setTurnServer(const TurnConfig& config) {
    turn_config_ = config;
    turn_configured_ = !config.uri.empty();
    use_cloudflare_turn_ = false;  // Disable Cloudflare if using static config
    if (turn_configured_) {
        LOG("TURN", "TURN server configured: " << config.uri);
    }
}

void WebRTCPeer::enableCloudflareTurn() {
    use_cloudflare_turn_ = true;
    turn_configured_ = true;  // Mark as configured
    LOG("TURN", "Cloudflare TURN enabled - credentials will be fetched dynamically");
}

bool WebRTCPeer::isUsingCloudflareTurn() {
    return use_cloudflare_turn_;
}

WebRTCPeer::WebRTCPeer(const std::string& viewer_id, GstElement* pipeline,
                       GstElement* video_tee, GstElement* audio_tee)
    : viewer_id_(viewer_id)
    , pipeline_(pipeline)
    , video_tee_(video_tee)
    , audio_tee_(audio_tee)
    , webrtcbin_(nullptr)
    , video_queue_(nullptr)
    , audio_queue_(nullptr)
    , video_tee_pad_(nullptr)
    , audio_tee_pad_(nullptr)
    , webrtc_video_sink_(nullptr)
    , webrtc_audio_sink_(nullptr)
    , video_tee_probe_id_(0)
    , video_queue_sink_probe_id_(0)
    , video_queue_src_probe_id_(0)
    , cleaned_up_(false)
    , remote_description_set_(false) {
    LOG_VAR("PEER", "WebRTCPeer created: ", viewer_id);
}

WebRTCPeer::~WebRTCPeer() {
    LOG_VAR("PEER", "WebRTCPeer destroying: ", viewer_id_);
    cleanup();
}

bool WebRTCPeer::initialize() {
    LOG_VAR("PEER", "Initializing peer: ", viewer_id_);

    // Create unique element names for this viewer
    std::string webrtc_name = "webrtc_" + viewer_id_;
    std::string vqueue_name = "vqueue_" + viewer_id_;
    std::string aqueue_name = "aqueue_" + viewer_id_;

    // Create webrtcbin
    webrtcbin_ = gst_element_factory_make("webrtcbin", webrtc_name.c_str());
    if (!webrtcbin_) {
        LOG("PEER-ERROR", "Failed to create webrtcbin");
        return false;
    }

    // Configure webrtcbin with STUN and optionally TURN
    g_object_set(webrtcbin_,
                 "bundle-policy", 3,  // max-bundle
                 "stun-server", "stun://stun.l.google.com:19302",
                 nullptr);

    // Add TURN server if configured (critical for NAT traversal)
    if (turn_configured_) {
        std::string turn_uri;

        if (use_cloudflare_turn_) {
            // Fetch dynamic credentials from Cloudflare
            LOG("PEER", "Fetching Cloudflare TURN credentials for: " << viewer_id_);
            turn_uri = CloudflareTurn::instance().getTurnUri();
            if (turn_uri.empty()) {
                LOG("PEER-ERROR", "Failed to get Cloudflare TURN credentials!");
            } else {
                // Log without credentials for security
                LOG("PEER", "Using Cloudflare TURN: turn.cloudflare.com:3478");
            }
        } else {
            // Use static TURN configuration
            turn_uri = turn_config_.uri;
            // Format: turn://username:password@server:port or turns:// for TLS
            if (!turn_config_.username.empty()) {
                // Insert credentials into URI
                size_t pos = turn_uri.find("://");
                if (pos != std::string::npos) {
                    turn_uri = turn_uri.substr(0, pos + 3) +
                              turn_config_.username + ":" +
                              turn_config_.password + "@" +
                              turn_uri.substr(pos + 3);
                }
            }
            LOG("PEER", "Setting TURN server: " << turn_config_.uri);
        }

        if (!turn_uri.empty()) {
            g_object_set(webrtcbin_, "turn-server", turn_uri.c_str(), nullptr);
        }
    } else {
        LOG("PEER-WARN", "No TURN server configured - NAT traversal may fail for remote viewers");
    }

    // Create queues for video and audio
    // IMPORTANT: Use larger queue to buffer data while webrtcbin negotiates
    video_queue_ = gst_element_factory_make("queue", vqueue_name.c_str());
    audio_queue_ = gst_element_factory_make("queue", aqueue_name.c_str());

    if (!video_queue_ || !audio_queue_) {
        LOG("PEER-ERROR", "Failed to create queue elements");
        return false;
    }

    // Configure queues with leaky=upstream to prevent blocking tee
    // If queue fills up (slow viewer), drop oldest buffers
    // This prevents one slow viewer from blocking all others
    g_object_set(video_queue_,
                 "max-size-buffers", 30,      // ~1 second at 30fps
                 "max-size-time", (guint64)1000000000,  // 1 second
                 "max-size-bytes", 0,
                 "leaky", 2,                  // 2 = upstream (drop oldest)
                 nullptr);
    g_object_set(audio_queue_,
                 "max-size-buffers", 50,
                 "max-size-time", (guint64)1000000000,  // 1 second
                 "max-size-bytes", 0,
                 "leaky", 2,                  // 2 = upstream (drop oldest)
                 nullptr);

    // Add elements to pipeline FIRST
    gst_bin_add_many(GST_BIN(pipeline_), video_queue_, audio_queue_, webrtcbin_, nullptr);

    // Get request pads from tees
    video_tee_pad_ = gst_element_request_pad_simple(video_tee_, "src_%u");
    audio_tee_pad_ = gst_element_request_pad_simple(audio_tee_, "src_%u");

    if (!video_tee_pad_ || !audio_tee_pad_) {
        LOG("PEER-ERROR", "Failed to get tee pads");
        return false;
    }

    LOG("PEER", "Got tee pads - video: " << GST_PAD_NAME(video_tee_pad_)
        << ", audio: " << GST_PAD_NAME(audio_tee_pad_));

    // Request sink pads from webrtcbin BEFORE linking
    // This allows webrtcbin to know about the media types
    webrtc_video_sink_ = gst_element_request_pad_simple(webrtcbin_, "sink_%u");
    webrtc_audio_sink_ = gst_element_request_pad_simple(webrtcbin_, "sink_%u");

    if (!webrtc_video_sink_ || !webrtc_audio_sink_) {
        LOG("PEER-ERROR", "Failed to get webrtcbin sink pads");
        return false;
    }

    LOG("PEER", "Got webrtcbin sink pads - video: " << GST_PAD_NAME(webrtc_video_sink_)
        << ", audio: " << GST_PAD_NAME(webrtc_audio_sink_));

    // Log caps from tee for debugging (but don't add transceivers - they're created by linking)
    GstCaps* video_caps = gst_pad_get_current_caps(video_tee_pad_);
    GstCaps* audio_caps = gst_pad_get_current_caps(audio_tee_pad_);

    if (video_caps) {
        gchar* caps_str = gst_caps_to_string(video_caps);
        LOG("PEER", "Video caps from tee: " << caps_str);
        g_free(caps_str);
        gst_caps_unref(video_caps);
    } else {
        LOG("PEER-WARN", "No video caps available from tee");
    }

    if (audio_caps) {
        gchar* caps_str = gst_caps_to_string(audio_caps);
        LOG("PEER", "Audio caps from tee: " << caps_str);
        g_free(caps_str);
        gst_caps_unref(audio_caps);
    } else {
        LOG("PEER-WARN", "No audio caps available from tee");
    }

    // Store viewer_id as C string for probes (will be valid for lifetime of peer)
    // We'll use a static map to store these
    static std::map<std::string, std::string> viewer_id_storage;
    viewer_id_storage[viewer_id_] = viewer_id_;
    const char* viewer_id_cstr = viewer_id_storage[viewer_id_].c_str();

    // CRITICAL FIX: For dynamic pipeline manipulation with tee elements,
    // downstream elements MUST be in PLAYING state BEFORE linking to tee
    // Otherwise, the tee's src pad remains in "flushing" mode and won't push data
    LOG("PEER", "Syncing element states BEFORE linking (critical for data flow)...");

    // First sync queues and webrtcbin to PLAYING state
    if (!gst_element_sync_state_with_parent(video_queue_)) {
        LOG("PEER-WARN", "Failed to sync video_queue state");
    }
    if (!gst_element_sync_state_with_parent(audio_queue_)) {
        LOG("PEER-WARN", "Failed to sync audio_queue state");
    }
    if (!gst_element_sync_state_with_parent(webrtcbin_)) {
        LOG("PEER-WARN", "Failed to sync webrtcbin state");
    }

    // Verify states before linking (use 1 second timeout, not infinite)
    GstState vq_state, aq_state, wb_state;
    GstStateChangeReturn vq_ret = gst_element_get_state(video_queue_, &vq_state, nullptr, GST_SECOND);
    GstStateChangeReturn aq_ret = gst_element_get_state(audio_queue_, &aq_state, nullptr, GST_SECOND);
    GstStateChangeReturn wb_ret = gst_element_get_state(webrtcbin_, &wb_state, nullptr, GST_SECOND);

    LOG("PEER", "Pre-link states - video_queue: " << gst_element_state_get_name(vq_state)
        << " (" << (vq_ret == GST_STATE_CHANGE_SUCCESS ? "OK" : "PENDING") << ")"
        << ", audio_queue: " << gst_element_state_get_name(aq_state)
        << " (" << (aq_ret == GST_STATE_CHANGE_SUCCESS ? "OK" : "PENDING") << ")"
        << ", webrtcbin: " << gst_element_state_get_name(wb_state)
        << " (" << (wb_ret == GST_STATE_CHANGE_SUCCESS ? "OK" : "PENDING") << ")");

    // Now link everything: tee -> queue -> webrtcbin
    // DIAGNOSTIC: Add probes at each stage to track data flow

    // Link: queue -> webrtcbin FIRST (so queue has a destination)
    LOG("PEER", "Linking queue -> webrtcbin first...");

    GstPad* vqueue_src = gst_element_get_static_pad(video_queue_, "src");
    // Add probe to track buffers reaching webrtcbin (store ID for cleanup)
    video_queue_src_probe_id_ = gst_pad_add_probe(vqueue_src, GST_PAD_PROBE_TYPE_BUFFER,
                     webrtc_buffer_probe, (gpointer)viewer_id_cstr, nullptr);
    LOG("PEER", "Added webrtcbin probe ID: " << video_queue_src_probe_id_);

    GstPadLinkReturn vwebrtc_result = gst_pad_link(vqueue_src, webrtc_video_sink_);
    gst_object_unref(vqueue_src);
    if (vwebrtc_result != GST_PAD_LINK_OK) {
        LOG("PEER-ERROR", "Failed to link video queue to webrtcbin, result: " << vwebrtc_result);
        return false;
    }
    LOG("PEER", "Linked video_queue -> webrtcbin");

    GstPad* aqueue_src = gst_element_get_static_pad(audio_queue_, "src");
    GstPadLinkReturn awebrtc_result = gst_pad_link(aqueue_src, webrtc_audio_sink_);
    gst_object_unref(aqueue_src);
    if (awebrtc_result != GST_PAD_LINK_OK) {
        LOG("PEER-ERROR", "Failed to link audio queue to webrtcbin, result: " << awebrtc_result);
        return false;
    }
    LOG("PEER", "Linked audio_queue -> webrtcbin");

    // NOW link tee -> queue (this completes the path and data should start flowing)
    LOG("PEER", "Linking tee -> queue (data flow should start)...");

    GstPad* vqueue_sink = gst_element_get_static_pad(video_queue_, "sink");

    // Add probe on tee src pad to see if tee is pushing data (store ID for cleanup)
    video_tee_probe_id_ = gst_pad_add_probe(video_tee_pad_, GST_PAD_PROBE_TYPE_BUFFER,
                     tee_src_probe, (gpointer)viewer_id_cstr, nullptr);
    LOG("PEER", "Added tee src probe ID: " << video_tee_probe_id_);

    // Add probe on queue sink to see if data enters queue (store ID for cleanup)
    video_queue_sink_probe_id_ = gst_pad_add_probe(vqueue_sink, GST_PAD_PROBE_TYPE_BUFFER,
                     queue_sink_probe, (gpointer)viewer_id_cstr, nullptr);
    LOG("PEER", "Added queue sink probe ID: " << video_queue_sink_probe_id_);

    GstPadLinkReturn vlink_result = gst_pad_link(video_tee_pad_, vqueue_sink);
    gst_object_unref(vqueue_sink);
    if (vlink_result != GST_PAD_LINK_OK) {
        LOG("PEER-ERROR", "Failed to link video tee to queue, result: " << vlink_result);
        return false;
    }
    LOG("PEER", "Linked video_tee -> video_queue");

    // Link: audio_tee -> audio_queue
    GstPad* aqueue_sink = gst_element_get_static_pad(audio_queue_, "sink");
    GstPadLinkReturn alink_result = gst_pad_link(audio_tee_pad_, aqueue_sink);
    gst_object_unref(aqueue_sink);
    if (alink_result != GST_PAD_LINK_OK) {
        LOG("PEER-ERROR", "Failed to link audio tee to queue, result: " << alink_result);
        return false;
    }
    LOG("PEER", "Linked audio_tee -> audio_queue");

    // Verify states after linking (use 1 second timeout, not infinite)
    GstState vq_state2, aq_state2, wb_state2;
    gst_element_get_state(video_queue_, &vq_state2, nullptr, GST_SECOND);
    gst_element_get_state(audio_queue_, &aq_state2, nullptr, GST_SECOND);
    gst_element_get_state(webrtcbin_, &wb_state2, nullptr, GST_SECOND);

    LOG("PEER", "Post-link states - video_queue: " << gst_element_state_get_name(vq_state2)
        << ", audio_queue: " << gst_element_state_get_name(aq_state2)
        << ", webrtcbin: " << gst_element_state_get_name(wb_state2));

    // Check queue src pad state and link status
    GstPad* vqueue_src_check = gst_element_get_static_pad(video_queue_, "src");
    if (vqueue_src_check) {
        GstPad* peer_pad = gst_pad_get_peer(vqueue_src_check);
        if (peer_pad) {
            LOG("PEER", "Video queue src pad is linked to: " << GST_PAD_NAME(peer_pad));
            gst_object_unref(peer_pad);
        } else {
            LOG("PEER-WARN", "Video queue src pad is NOT linked!");
        }
        gst_object_unref(vqueue_src_check);
    }

    // Check tee pad caps
    GstCaps* tee_caps = gst_pad_get_current_caps(video_tee_pad_);
    if (tee_caps) {
        gchar* caps_str = gst_caps_to_string(tee_caps);
        LOG("PEER", "Tee src pad caps: " << caps_str);
        g_free(caps_str);
        gst_caps_unref(tee_caps);
    } else {
        LOG("PEER-WARN", "Tee src pad has NO CAPS - this may be the problem!");
    }

    // Connect signals
    g_signal_connect(webrtcbin_, "on-negotiation-needed",
                    G_CALLBACK(onNegotiationNeeded), this);
    g_signal_connect(webrtcbin_, "on-ice-candidate",
                    G_CALLBACK(onIceCandidate), this);

    // CRITICAL: Monitor ICE connection state to debug connection issues
    g_signal_connect(webrtcbin_, "notify::ice-connection-state",
                    G_CALLBACK(onIceConnectionStateChange), this);
    g_signal_connect(webrtcbin_, "notify::connection-state",
                    G_CALLBACK(onConnectionStateChange), this);
    g_signal_connect(webrtcbin_, "notify::ice-gathering-state",
                    G_CALLBACK(onIceGatheringStateChange), this);

    LOG_VAR("PEER", "Peer initialized successfully: ", viewer_id_);
    return true;
}

void WebRTCPeer::cleanup() {
    // Thread-safe cleanup with double-cleanup prevention
    std::lock_guard<std::mutex> lock(cleanup_mutex_);

    if (cleaned_up_) {
        LOG_VAR("PEER", "Already cleaned up, skipping: ", viewer_id_);
        return;
    }

    LOG_VAR("PEER", "Cleaning up peer: ", viewer_id_);

    // Clear ICE candidate queue first
    {
        std::lock_guard<std::mutex> ice_lock(ice_mutex_);
        queued_ice_candidates_.clear();
        remote_description_set_.store(false);
    }

    if (!pipeline_) {
        cleaned_up_ = true;
        return;
    }

    // Mark as cleaned up early to prevent concurrent cleanup attempts
    cleaned_up_ = true;

    // CRITICAL: For safe dynamic pipeline removal, we must:
    // 0. Disconnect all signal handlers FIRST (prevents callbacks during cleanup)
    // 1. Remove probes (prevents buffer callbacks during cleanup)
    // 2. Unlink pads
    // 3. Release request pads
    // 4. Set elements to NULL
    // 5. Remove from bin

    // STEP 0: Disconnect ALL signal handlers FIRST to prevent ICE/state callbacks on destroyed object
    LOG("PEER", "Disconnecting signal handlers...");
    if (webrtcbin_) {
        // Disconnect all signals connected with 'this' as user_data
        // This prevents ICE state change callbacks from firing after cleanup starts
        g_signal_handlers_disconnect_by_data(webrtcbin_, this);
        LOG("PEER", "Disconnected all signal handlers from webrtcbin");
    }

    // STEP 1: Remove all probes to prevent buffer callbacks during cleanup
    LOG("PEER", "Removing probes...");
    if (video_tee_pad_ && video_tee_probe_id_ != 0) {
        gst_pad_remove_probe(video_tee_pad_, video_tee_probe_id_);
        LOG("PEER", "Removed tee src probe");
        video_tee_probe_id_ = 0;
    }
    if (video_queue_) {
        if (video_queue_sink_probe_id_ != 0) {
            GstPad* queue_sink = gst_element_get_static_pad(video_queue_, "sink");
            if (queue_sink) {
                gst_pad_remove_probe(queue_sink, video_queue_sink_probe_id_);
                gst_object_unref(queue_sink);
                LOG("PEER", "Removed queue sink probe");
            }
            video_queue_sink_probe_id_ = 0;
        }
        if (video_queue_src_probe_id_ != 0) {
            GstPad* queue_src = gst_element_get_static_pad(video_queue_, "src");
            if (queue_src) {
                gst_pad_remove_probe(queue_src, video_queue_src_probe_id_);
                gst_object_unref(queue_src);
                LOG("PEER", "Removed queue src probe");
            }
            video_queue_src_probe_id_ = 0;
        }
    }

    // STEP 1: Unlink everything
    LOG("PEER", "Unlinking pads...");

    // Unlink video path: tee -> queue -> webrtcbin
    if (video_tee_pad_ && video_queue_) {
        GstPad* queue_sink = gst_element_get_static_pad(video_queue_, "sink");
        if (queue_sink) {
            if (gst_pad_is_linked(video_tee_pad_)) {
                gst_pad_unlink(video_tee_pad_, queue_sink);
                LOG("PEER", "Unlinked video_tee -> video_queue");
            }
            gst_object_unref(queue_sink);
        }
    }

    if (video_queue_ && webrtc_video_sink_) {
        GstPad* queue_src = gst_element_get_static_pad(video_queue_, "src");
        if (queue_src) {
            if (gst_pad_is_linked(queue_src)) {
                gst_pad_unlink(queue_src, webrtc_video_sink_);
                LOG("PEER", "Unlinked video_queue -> webrtcbin");
            }
            gst_object_unref(queue_src);
        }
    }

    // Unlink audio path: tee -> queue -> webrtcbin
    if (audio_tee_pad_ && audio_queue_) {
        GstPad* queue_sink = gst_element_get_static_pad(audio_queue_, "sink");
        if (queue_sink) {
            if (gst_pad_is_linked(audio_tee_pad_)) {
                gst_pad_unlink(audio_tee_pad_, queue_sink);
                LOG("PEER", "Unlinked audio_tee -> audio_queue");
            }
            gst_object_unref(queue_sink);
        }
    }

    if (audio_queue_ && webrtc_audio_sink_) {
        GstPad* queue_src = gst_element_get_static_pad(audio_queue_, "src");
        if (queue_src) {
            if (gst_pad_is_linked(queue_src)) {
                gst_pad_unlink(queue_src, webrtc_audio_sink_);
                LOG("PEER", "Unlinked audio_queue -> webrtcbin");
            }
            gst_object_unref(queue_src);
        }
    }

    // Release tee request pads BEFORE setting elements to NULL
    // This is critical - releasing while linked can cause issues
    if (video_tee_pad_ && video_tee_) {
        gst_element_release_request_pad(video_tee_, video_tee_pad_);
        gst_object_unref(video_tee_pad_);
        video_tee_pad_ = nullptr;
        LOG("PEER", "Released video tee pad");
    }
    if (audio_tee_pad_ && audio_tee_) {
        gst_element_release_request_pad(audio_tee_, audio_tee_pad_);
        gst_object_unref(audio_tee_pad_);
        audio_tee_pad_ = nullptr;
        LOG("PEER", "Released audio tee pad");
    }

    // Release webrtcbin sink pads
    if (webrtc_video_sink_ && webrtcbin_) {
        gst_element_release_request_pad(webrtcbin_, webrtc_video_sink_);
        gst_object_unref(webrtc_video_sink_);
        webrtc_video_sink_ = nullptr;
    }
    if (webrtc_audio_sink_ && webrtcbin_) {
        gst_element_release_request_pad(webrtcbin_, webrtc_audio_sink_);
        gst_object_unref(webrtc_audio_sink_);
        webrtc_audio_sink_ = nullptr;
    }

    // NOW set elements to NULL state (after unlinking)
    // Use locked state and non-blocking approach to prevent cleanup from hanging
    LOG("PEER", "Setting elements to NULL state...");

    // Lock states to prevent any blocking during cleanup
    if (video_queue_) {
        gst_element_set_locked_state(video_queue_, TRUE);
        gst_element_set_state(video_queue_, GST_STATE_NULL);
        LOG("PEER", "video_queue set to NULL (locked)");
    }
    if (audio_queue_) {
        gst_element_set_locked_state(audio_queue_, TRUE);
        gst_element_set_state(audio_queue_, GST_STATE_NULL);
        LOG("PEER", "audio_queue set to NULL (locked)");
    }

    // webrtcbin cleanup - this is the critical one with ICE agent
    if (webrtcbin_) {
        LOG("PEER", "Setting webrtcbin to NULL (this triggers ICE/TURN cleanup)...");
        gst_element_set_locked_state(webrtcbin_, TRUE);
        gst_element_set_state(webrtcbin_, GST_STATE_NULL);

        // Wait briefly for webrtcbin, but don't block forever
        GstStateChangeReturn ret = gst_element_get_state(webrtcbin_, nullptr, nullptr, 500 * GST_MSECOND);
        if (ret == GST_STATE_CHANGE_SUCCESS) {
            LOG("PEER", "webrtcbin state change to NULL completed");
        } else {
            LOG("PEER-WARN", "webrtcbin state change returned: " << ret << " (continuing anyway)");
        }
    }

    // Run GLib main loop iterations to let libnice TURN refresh timers fire and cleanup
    // This is critical - just sleeping doesn't help because libnice uses the main loop
    LOG("PEER", "Running main loop for TURN cleanup (500ms)...");
    GMainContext* context = g_main_context_default();
    gint64 end_time = g_get_monotonic_time() + 500000;  // 500ms
    while (g_get_monotonic_time() < end_time) {
        g_main_context_iteration(context, FALSE);
        g_usleep(10000);  // 10ms between iterations
    }
    LOG("PEER", "Main loop cleanup complete");

    // Remove elements from pipeline
    LOG("PEER", "Removing elements from pipeline...");
    if (video_queue_) {
        gst_bin_remove(GST_BIN(pipeline_), video_queue_);
        video_queue_ = nullptr;
    }
    if (audio_queue_) {
        gst_bin_remove(GST_BIN(pipeline_), audio_queue_);
        audio_queue_ = nullptr;
    }
    if (webrtcbin_) {
        gst_bin_remove(GST_BIN(pipeline_), webrtcbin_);
        webrtcbin_ = nullptr;
    }

    LOG_VAR("PEER", "Peer cleanup complete: ", viewer_id_);
}

void WebRTCPeer::createOffer(std::function<void(const std::string&)> callback) {
    LOG_VAR("PEER", "Creating offer for: ", viewer_id_);
    offer_callback_ = callback;

    // CRITICAL: Wait for transceivers to be created from pad linking
    // Webrtcbin creates transceivers when data flows through sink pads
    // We need to wait until we have both video and audio transceivers
    int wait_count = 0;
    const int max_wait = 20;  // Max 200ms wait (20 * 10ms)

    while (wait_count < max_wait) {
        GArray* transceivers = nullptr;
        g_signal_emit_by_name(webrtcbin_, "get-transceivers", &transceivers);

        if (transceivers) {
            guint count = transceivers->len;
            g_array_unref(transceivers);

            if (count >= 2) {
                LOG("PEER", viewer_id_ << " has " << count << " transceivers - ready to create offer");
                break;
            }
            LOG("PEER", viewer_id_ << " waiting for transceivers... currently " << count);
        }

        g_usleep(10000);  // 10ms
        wait_count++;
    }

    if (wait_count >= max_wait) {
        LOG("PEER-WARN", viewer_id_ << " timeout waiting for transceivers - offer may be incomplete");
    }

    GstPromise* promise = gst_promise_new_with_change_func(onOfferCreated, this, nullptr);
    g_signal_emit_by_name(webrtcbin_, "create-offer", nullptr, promise);
}

void WebRTCPeer::onOfferCreated(GstPromise* promise, gpointer user_data) {
    WebRTCPeer* peer = static_cast<WebRTCPeer*>(user_data);
    LOG_VAR("PEER", "Offer created for: ", peer->viewer_id_);

    GstWebRTCSessionDescription* offer = nullptr;
    const GstStructure* reply = gst_promise_get_reply(promise);
    gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, nullptr);
    gst_promise_unref(promise);

    if (!offer) {
        LOG("PEER-ERROR", "Failed to get offer from promise");
        return;
    }

    // Set local description
    GstPromise* local_promise = gst_promise_new();
    g_signal_emit_by_name(peer->webrtcbin_, "set-local-description", offer, local_promise);
    gst_promise_interrupt(local_promise);
    gst_promise_unref(local_promise);

    // Get SDP string
    gchar* sdp_string = gst_sdp_message_as_text(offer->sdp);
    std::string sdp(sdp_string);
    g_free(sdp_string);

    LOG_VAR("PEER", "SDP offer length: ", sdp.length());

    // Log SDP details for debugging multi-viewer issues
    // Extract key info: media lines, ice-ufrag, ice-pwd
    size_t video_pos = sdp.find("m=video");
    size_t audio_pos = sdp.find("m=audio");
    size_t ufrag_pos = sdp.find("a=ice-ufrag:");
    size_t pwd_pos = sdp.find("a=ice-pwd:");

    LOG("SDP-DEBUG", peer->viewer_id_ << " SDP contains video: " << (video_pos != std::string::npos ? "YES" : "NO")
        << ", audio: " << (audio_pos != std::string::npos ? "YES" : "NO"));

    if (ufrag_pos != std::string::npos) {
        size_t ufrag_end = sdp.find("\r\n", ufrag_pos);
        std::string ufrag = sdp.substr(ufrag_pos + 12, std::min((size_t)20, ufrag_end - ufrag_pos - 12));
        LOG("SDP-DEBUG", peer->viewer_id_ << " ice-ufrag: " << ufrag);
    }
    if (pwd_pos != std::string::npos) {
        size_t pwd_end = sdp.find("\r\n", pwd_pos);
        std::string pwd = sdp.substr(pwd_pos + 10, std::min((size_t)8, pwd_end - pwd_pos - 10)) + "...";
        LOG("SDP-DEBUG", peer->viewer_id_ << " ice-pwd: " << pwd);
    }

    if (peer->offer_callback_) {
        peer->offer_callback_(sdp);
    }

    gst_webrtc_session_description_free(offer);
}

void WebRTCPeer::setRemoteAnswer(const std::string& sdp) {
    LOG_VAR("PEER", "Setting remote answer for: ", viewer_id_);
    LOG("SDP-DEBUG", viewer_id_ << " Answer SDP length: " << sdp.length());

    // Log answer SDP details
    size_t video_pos = sdp.find("m=video");
    size_t audio_pos = sdp.find("m=audio");
    LOG("SDP-DEBUG", viewer_id_ << " Answer contains video: " << (video_pos != std::string::npos ? "YES" : "NO")
        << ", audio: " << (audio_pos != std::string::npos ? "YES" : "NO"));

    // Check if audio track was rejected (port 0)
    if (audio_pos != std::string::npos) {
        size_t port_start = audio_pos + 8; // after "m=audio "
        size_t port_end = sdp.find(" ", port_start);
        if (port_end != std::string::npos) {
            std::string port = sdp.substr(port_start, port_end - port_start);
            if (port == "0") {
                LOG("SDP-DEBUG", viewer_id_ << " WARNING: Browser REJECTED audio track (port=0)");
            }
        }
    }

    GstSDPMessage* sdp_msg;
    gst_sdp_message_new(&sdp_msg);
    gst_sdp_message_parse_buffer((guint8*)sdp.c_str(), sdp.length(), sdp_msg);

    GstWebRTCSessionDescription* answer =
        gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdp_msg);

    // Set remote description synchronously first
    GstPromise* promise = gst_promise_new();
    g_signal_emit_by_name(webrtcbin_, "set-remote-description", answer, promise);

    // Wait for it to complete with a timeout
    GstPromiseResult result = gst_promise_wait(promise);
    gst_promise_unref(promise);

    if (result == GST_PROMISE_RESULT_REPLIED) {
        LOG("PEER", "Remote description set successfully for: " << viewer_id_);
    } else {
        LOG("PEER-WARN", "Remote description set with result: " << result << " for: " << viewer_id_);
    }

    gst_webrtc_session_description_free(answer);

    // CRITICAL: Mark remote description as set AFTER it's fully applied
    // This ensures all ICE candidates received before this point are queued
    remote_description_set_.store(true);
    LOG_VAR("PEER", "Remote answer applied for: ", viewer_id_);

    // Now process any queued ICE candidates
    processQueuedIceCandidates();
}

void WebRTCPeer::addIceCandidate(const std::string& candidate, int sdp_mline_index) {
    // CRITICAL FIX for libnice crash:
    // Queue ICE candidates until remote description is set
    // Adding candidates too early or too rapidly causes libnice assertion failures

    std::lock_guard<std::mutex> lock(ice_mutex_);

    if (!remote_description_set_.load()) {
        // Queue the candidate - will be processed after setRemoteAnswer
        LOG("PEER", "Queuing ICE candidate for " << viewer_id_ << " (remote desc not set), mlineindex: " << sdp_mline_index);
        queued_ice_candidates_.push_back({candidate, sdp_mline_index});
        return;
    }

    // Remote description is set, add candidate directly
    LOG("PEER", "Adding ICE candidate for " << viewer_id_ << ", mlineindex: " << sdp_mline_index);
    g_signal_emit_by_name(webrtcbin_, "add-ice-candidate", sdp_mline_index, candidate.c_str());
}

void WebRTCPeer::processQueuedIceCandidates() {
    std::lock_guard<std::mutex> lock(ice_mutex_);

    if (queued_ice_candidates_.empty()) {
        LOG("PEER", "No queued ICE candidates to process for " << viewer_id_);
        return;
    }

    LOG("PEER", "Processing " << queued_ice_candidates_.size() << " queued ICE candidates for " << viewer_id_);

    // Process candidates with a small delay between each to avoid overwhelming libnice
    for (size_t i = 0; i < queued_ice_candidates_.size(); i++) {
        const auto& ice = queued_ice_candidates_[i];
        LOG("PEER", "Adding queued ICE candidate " << (i+1) << "/" << queued_ice_candidates_.size()
            << " for " << viewer_id_ << ", mlineindex: " << ice.sdp_mline_index);
        g_signal_emit_by_name(webrtcbin_, "add-ice-candidate", ice.sdp_mline_index, ice.candidate.c_str());
    }

    LOG("PEER", "Finished processing queued ICE candidates for " << viewer_id_);
    queued_ice_candidates_.clear();
}

void WebRTCPeer::onNegotiationNeeded(GstElement* webrtc, gpointer user_data) {
    WebRTCPeer* peer = static_cast<WebRTCPeer*>(user_data);
    LOG_VAR("PEER", "on-negotiation-needed for: ", peer->viewer_id_);
}

void WebRTCPeer::onIceCandidate(GstElement* webrtc, guint mlineindex,
                                gchar* candidate, gpointer user_data) {
    WebRTCPeer* peer = static_cast<WebRTCPeer*>(user_data);
    std::string cand_str(candidate ? candidate : "");

    if (!cand_str.empty()) {
        LOG("PEER", "ICE candidate for " << peer->viewer_id_ << ": " << cand_str.substr(0, 60));
        if (peer->ice_candidate_callback_) {
            peer->ice_candidate_callback_(cand_str, mlineindex);
        }
    } else {
        LOG_VAR("PEER", "ICE gathering complete for: ", peer->viewer_id_);
    }
}

// ICE connection state callback - CRITICAL for debugging connection issues
void WebRTCPeer::onIceConnectionStateChange(GstElement* webrtc, GParamSpec* pspec, gpointer user_data) {
    WebRTCPeer* peer = static_cast<WebRTCPeer*>(user_data);

    guint ice_state;
    g_object_get(webrtc, "ice-connection-state", &ice_state, nullptr);

    const char* state_names[] = {
        "new", "checking", "connected", "completed", "failed", "disconnected", "closed"
    };
    const char* state_name = (ice_state < 7) ? state_names[ice_state] : "unknown";

    LOG("ICE-STATE", peer->viewer_id_ << " ICE connection state: " << state_name << " (" << ice_state << ")");

    // Log when connection is established or fails
    if (ice_state == 2) { // connected
        LOG("ICE-STATE", peer->viewer_id_ << " >>> ICE CONNECTED - data should flow now <<<");
    } else if (ice_state == 3) { // completed
        LOG("ICE-STATE", peer->viewer_id_ << " >>> ICE COMPLETED - all candidates checked <<<");
    } else if (ice_state == 4) { // failed
        LOG("ICE-STATE", peer->viewer_id_ << " >>> ICE FAILED - connection could not be established <<<");
    }
}

// WebRTC connection state callback
void WebRTCPeer::onConnectionStateChange(GstElement* webrtc, GParamSpec* pspec, gpointer user_data) {
    WebRTCPeer* peer = static_cast<WebRTCPeer*>(user_data);

    guint conn_state;
    g_object_get(webrtc, "connection-state", &conn_state, nullptr);

    const char* state_names[] = {
        "new", "connecting", "connected", "disconnected", "failed", "closed"
    };
    const char* state_name = (conn_state < 6) ? state_names[conn_state] : "unknown";

    LOG("CONN-STATE", peer->viewer_id_ << " connection state: " << state_name << " (" << conn_state << ")");
}

// ICE gathering state callback - shows when local candidate gathering is complete
void WebRTCPeer::onIceGatheringStateChange(GstElement* webrtc, GParamSpec* pspec, gpointer user_data) {
    WebRTCPeer* peer = static_cast<WebRTCPeer*>(user_data);

    guint gather_state;
    g_object_get(webrtc, "ice-gathering-state", &gather_state, nullptr);

    const char* state_names[] = {
        "new", "gathering", "complete"
    };
    const char* state_name = (gather_state < 3) ? state_names[gather_state] : "unknown";

    LOG("ICE-GATHER", peer->viewer_id_ << " ICE gathering state: " << state_name << " (" << gather_state << ")");

    if (gather_state == 2) { // complete
        LOG("ICE-GATHER", peer->viewer_id_ << " >>> All local ICE candidates gathered <<<");
    }
}

void WebRTCPeer::setIceCandidateCallback(
    std::function<void(const std::string&, int)> callback) {
    ice_candidate_callback_ = callback;
}
