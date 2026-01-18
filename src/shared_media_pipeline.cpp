#include "shared_media_pipeline.h"
#include <gst/sdp/sdp.h>
#include <gst/webrtc/webrtc.h>
#include <gst/video/video.h>
#include <iostream>
#include <chrono>
#include <iomanip>
#include <sstream>

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
    std::lock_guard<std::mutex> lock(mutex_);

    LOG_VAR("SHARED", "Adding viewer: ", viewer_id);

    // Check if viewer already exists
    auto it = viewers_.find(viewer_id);
    if (it != viewers_.end()) {
        LOG_VAR("SHARED", "Viewer already exists: ", viewer_id);
        return it->second;
    }

    // Create new peer
    WebRTCPeer* peer = new WebRTCPeer(viewer_id, pipeline_, video_tee_, audio_tee_);
    if (!peer->initialize()) {
        LOG_VAR("SHARED-ERROR", "Failed to initialize peer: ", viewer_id);
        delete peer;
        return nullptr;
    }

    viewers_[viewer_id] = peer;
    LOG_VAR("SHARED", "Viewer added successfully. Total viewers: ", viewers_.size());

    return peer;
}

void SharedMediaPipeline::removeViewer(const std::string& viewer_id) {
    std::lock_guard<std::mutex> lock(mutex_);

    LOG_VAR("SHARED", "Removing viewer: ", viewer_id);

    auto it = viewers_.find(viewer_id);
    if (it != viewers_.end()) {
        // Delete will call destructor which calls cleanup()
        // No need to call cleanup() explicitly - prevents race conditions
        delete it->second;
        viewers_.erase(it);
        LOG_VAR("SHARED", "Viewer removed. Total viewers: ", viewers_.size());
    }
}

// ==================== WebRTCPeer Implementation ====================

// Buffer probe to count buffers reaching webrtcbin
static GstPadProbeReturn webrtc_buffer_probe(GstPad* pad, GstPadProbeInfo* info, gpointer user_data) {
    static guint64 webrtc_buffer_count = 0;
    webrtc_buffer_count++;
    if (webrtc_buffer_count % 100 == 0) {
        LOG("PROBE", "Buffers reaching webrtcbin: " << webrtc_buffer_count);
    }
    return GST_PAD_PROBE_OK;
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
    , cleaned_up_(false) {
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

    // Configure webrtcbin
    g_object_set(webrtcbin_,
                 "bundle-policy", 3,  // max-bundle
                 "stun-server", "stun://stun.l.google.com:19302",
                 nullptr);

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

    // Now link everything: tee -> queue -> webrtcbin

    // Link: video_tee -> video_queue
    GstPad* vqueue_sink = gst_element_get_static_pad(video_queue_, "sink");
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

    // Link: video_queue -> webrtcbin
    GstPad* vqueue_src = gst_element_get_static_pad(video_queue_, "src");
    GstPadLinkReturn vwebrtc_result = gst_pad_link(vqueue_src, webrtc_video_sink_);

    // Add probe to track buffers reaching webrtcbin
    gst_pad_add_probe(vqueue_src, GST_PAD_PROBE_TYPE_BUFFER,
                     webrtc_buffer_probe, nullptr, nullptr);

    gst_object_unref(vqueue_src);
    if (vwebrtc_result != GST_PAD_LINK_OK) {
        LOG("PEER-ERROR", "Failed to link video queue to webrtcbin, result: " << vwebrtc_result);
        return false;
    }
    LOG("PEER", "Linked video_queue -> webrtcbin");

    // Link: audio_queue -> webrtcbin
    GstPad* aqueue_src = gst_element_get_static_pad(audio_queue_, "src");
    GstPadLinkReturn awebrtc_result = gst_pad_link(aqueue_src, webrtc_audio_sink_);
    gst_object_unref(aqueue_src);
    if (awebrtc_result != GST_PAD_LINK_OK) {
        LOG("PEER-ERROR", "Failed to link audio queue to webrtcbin, result: " << awebrtc_result);
        return false;
    }
    LOG("PEER", "Linked audio_queue -> webrtcbin");

    // NOW sync state after everything is linked
    LOG("PEER", "Syncing element states with pipeline...");
    if (!gst_element_sync_state_with_parent(video_queue_)) {
        LOG("PEER-WARN", "Failed to sync video_queue state");
    }
    if (!gst_element_sync_state_with_parent(audio_queue_)) {
        LOG("PEER-WARN", "Failed to sync audio_queue state");
    }
    if (!gst_element_sync_state_with_parent(webrtcbin_)) {
        LOG("PEER-WARN", "Failed to sync webrtcbin state");
    }

    // Connect signals
    g_signal_connect(webrtcbin_, "on-negotiation-needed",
                    G_CALLBACK(onNegotiationNeeded), this);
    g_signal_connect(webrtcbin_, "on-ice-candidate",
                    G_CALLBACK(onIceCandidate), this);

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

    if (!pipeline_) {
        cleaned_up_ = true;
        return;
    }

    // Mark as cleaned up early to prevent concurrent cleanup attempts
    cleaned_up_ = true;

    // CRITICAL: For safe dynamic pipeline removal, we must:
    // 1. Unlink pads first
    // 2. Release request pads
    // 3. Set elements to NULL
    // 4. Remove from bin

    // First, unlink everything
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
    if (video_queue_) {
        gst_element_set_state(video_queue_, GST_STATE_NULL);
    }
    if (audio_queue_) {
        gst_element_set_state(audio_queue_, GST_STATE_NULL);
    }
    if (webrtcbin_) {
        gst_element_set_state(webrtcbin_, GST_STATE_NULL);
    }

    // Remove elements from pipeline
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

    if (peer->offer_callback_) {
        peer->offer_callback_(sdp);
    }

    gst_webrtc_session_description_free(offer);
}

void WebRTCPeer::setRemoteAnswer(const std::string& sdp) {
    LOG_VAR("PEER", "Setting remote answer for: ", viewer_id_);

    GstSDPMessage* sdp_msg;
    gst_sdp_message_new(&sdp_msg);
    gst_sdp_message_parse_buffer((guint8*)sdp.c_str(), sdp.length(), sdp_msg);

    GstWebRTCSessionDescription* answer =
        gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdp_msg);

    GstPromise* promise = gst_promise_new();
    g_signal_emit_by_name(webrtcbin_, "set-remote-description", answer, promise);
    gst_promise_interrupt(promise);
    gst_promise_unref(promise);

    gst_webrtc_session_description_free(answer);
    LOG_VAR("PEER", "Remote answer set for: ", viewer_id_);
}

void WebRTCPeer::addIceCandidate(const std::string& candidate, int sdp_mline_index) {
    LOG("PEER", "Adding ICE candidate for " << viewer_id_ << ", mlineindex: " << sdp_mline_index);
    g_signal_emit_by_name(webrtcbin_, "add-ice-candidate", sdp_mline_index, candidate.c_str());
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

void WebRTCPeer::setIceCandidateCallback(
    std::function<void(const std::string&, int)> callback) {
    ice_candidate_callback_ = callback;
}
