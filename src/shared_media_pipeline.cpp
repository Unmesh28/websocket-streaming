#include "shared_media_pipeline.h"
#include <gst/sdp/sdp.h>
#include <gst/webrtc/webrtc.h>
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
            "queue max-size-buffers=1 leaky=downstream ! ";
    }

    // Create pipeline with tee elements for multi-viewer support
    // The video and audio are encoded once and distributed via tee elements
    std::string pipeline_str =
        // Video capture and encoding (shared)
        video_source +
        "x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=15 bframes=0 ! "
        "h264parse config-interval=1 ! "
        "rtph264pay config-interval=1 pt=96 ! "
        "application/x-rtp,media=video,encoding-name=H264,payload=96 ! "
        "tee name=video_tee allow-not-linked=true "

        // Audio capture and encoding (shared)
        "alsasrc device=" + audio_device + " ! "
        "audioconvert ! "
        "audioresample ! "
        "audio/x-raw,rate=48000,channels=1 ! "
        "queue max-size-buffers=1 leaky=downstream ! "
        "opusenc bitrate=32000 ! "
        "rtpopuspay pt=97 ! "
        "application/x-rtp,media=audio,encoding-name=OPUS,payload=97 ! "
        "tee name=audio_tee allow-not-linked=true";

    LOG("SHARED", "Creating shared pipeline...");
    LOG("SHARED", "Pipeline: " << pipeline_str.substr(0, 300) << "...");

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

    LOG("SHARED", "Shared pipeline created successfully with tee elements");
    return true;
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
        it->second->cleanup();
        delete it->second;
        viewers_.erase(it);
        LOG_VAR("SHARED", "Viewer removed. Total viewers: ", viewers_.size());
    }
}

// ==================== WebRTCPeer Implementation ====================

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
    , webrtc_audio_sink_(nullptr) {
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
    video_queue_ = gst_element_factory_make("queue", vqueue_name.c_str());
    audio_queue_ = gst_element_factory_make("queue", aqueue_name.c_str());

    if (!video_queue_ || !audio_queue_) {
        LOG("PEER-ERROR", "Failed to create queue elements");
        return false;
    }

    // Configure queues for low latency
    g_object_set(video_queue_, "max-size-buffers", 1, "leaky", 2, nullptr);  // leaky=downstream
    g_object_set(audio_queue_, "max-size-buffers", 1, "leaky", 2, nullptr);

    // Add elements to pipeline
    gst_bin_add_many(GST_BIN(pipeline_), video_queue_, audio_queue_, webrtcbin_, nullptr);

    // Sync state BEFORE linking (elements must be in at least PAUSED state)
    gst_element_sync_state_with_parent(video_queue_);
    gst_element_sync_state_with_parent(audio_queue_);
    gst_element_sync_state_with_parent(webrtcbin_);

    // Get request pads from tees
    video_tee_pad_ = gst_element_request_pad_simple(video_tee_, "src_%u");
    audio_tee_pad_ = gst_element_request_pad_simple(audio_tee_, "src_%u");

    if (!video_tee_pad_ || !audio_tee_pad_) {
        LOG("PEER-ERROR", "Failed to get tee pads");
        return false;
    }

    LOG("PEER", "Got tee pads - video: " << GST_PAD_NAME(video_tee_pad_)
        << ", audio: " << GST_PAD_NAME(audio_tee_pad_));

    // Link: video_tee -> video_queue
    GstPad* vqueue_sink = gst_element_get_static_pad(video_queue_, "sink");
    GstPadLinkReturn vlink_result = gst_pad_link(video_tee_pad_, vqueue_sink);
    if (vlink_result != GST_PAD_LINK_OK) {
        LOG("PEER-ERROR", "Failed to link video tee to queue, result: " << vlink_result);
        gst_object_unref(vqueue_sink);
        return false;
    }
    gst_object_unref(vqueue_sink);
    LOG("PEER", "Linked video_tee -> video_queue");

    // Link: audio_tee -> audio_queue
    GstPad* aqueue_sink = gst_element_get_static_pad(audio_queue_, "sink");
    GstPadLinkReturn alink_result = gst_pad_link(audio_tee_pad_, aqueue_sink);
    if (alink_result != GST_PAD_LINK_OK) {
        LOG("PEER-ERROR", "Failed to link audio tee to queue, result: " << alink_result);
        gst_object_unref(aqueue_sink);
        return false;
    }
    gst_object_unref(aqueue_sink);
    LOG("PEER", "Linked audio_tee -> audio_queue");

    // Request sink pads from webrtcbin (webrtcbin uses request pads, not static pads)
    webrtc_video_sink_ = gst_element_request_pad_simple(webrtcbin_, "sink_%u");
    webrtc_audio_sink_ = gst_element_request_pad_simple(webrtcbin_, "sink_%u");

    if (!webrtc_video_sink_ || !webrtc_audio_sink_) {
        LOG("PEER-ERROR", "Failed to get webrtcbin sink pads");
        return false;
    }

    LOG("PEER", "Got webrtcbin sink pads - video: " << GST_PAD_NAME(webrtc_video_sink_)
        << ", audio: " << GST_PAD_NAME(webrtc_audio_sink_));

    // Link: video_queue -> webrtcbin
    GstPad* vqueue_src = gst_element_get_static_pad(video_queue_, "src");
    GstPadLinkReturn vwebrtc_result = gst_pad_link(vqueue_src, webrtc_video_sink_);
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

    // Connect signals
    g_signal_connect(webrtcbin_, "on-negotiation-needed",
                    G_CALLBACK(onNegotiationNeeded), this);
    g_signal_connect(webrtcbin_, "on-ice-candidate",
                    G_CALLBACK(onIceCandidate), this);

    LOG_VAR("PEER", "Peer initialized successfully: ", viewer_id_);
    return true;
}

void WebRTCPeer::cleanup() {
    LOG_VAR("PEER", "Cleaning up peer: ", viewer_id_);

    if (!pipeline_) return;

    // Set elements to NULL state
    if (webrtcbin_) {
        gst_element_set_state(webrtcbin_, GST_STATE_NULL);
    }
    if (video_queue_) {
        gst_element_set_state(video_queue_, GST_STATE_NULL);
    }
    if (audio_queue_) {
        gst_element_set_state(audio_queue_, GST_STATE_NULL);
    }

    // Release tee pads
    if (video_tee_pad_ && video_tee_) {
        gst_element_release_request_pad(video_tee_, video_tee_pad_);
        gst_object_unref(video_tee_pad_);
        video_tee_pad_ = nullptr;
    }
    if (audio_tee_pad_ && audio_tee_) {
        gst_element_release_request_pad(audio_tee_, audio_tee_pad_);
        gst_object_unref(audio_tee_pad_);
        audio_tee_pad_ = nullptr;
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

    // Remove elements from pipeline
    if (webrtcbin_) {
        gst_bin_remove(GST_BIN(pipeline_), webrtcbin_);
        webrtcbin_ = nullptr;
    }
    if (video_queue_) {
        gst_bin_remove(GST_BIN(pipeline_), video_queue_);
        video_queue_ = nullptr;
    }
    if (audio_queue_) {
        gst_bin_remove(GST_BIN(pipeline_), audio_queue_);
        audio_queue_ = nullptr;
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
