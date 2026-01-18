#include "webrtc_stream.h"
#include <gst/sdp/sdp.h>
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
    WebRTCStream* stream = static_cast<WebRTCStream*>(user_data);

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
            if (GST_MESSAGE_SRC(msg) == GST_OBJECT(stream->getPipeline())) {
                GstState old_state, new_state, pending;
                gst_message_parse_state_changed(msg, &old_state, &new_state, &pending);
                LOG("GST-STATE", "Pipeline state: " <<
                    gst_element_state_get_name(old_state) << " -> " <<
                    gst_element_state_get_name(new_state));
            }
            break;
        }
        case GST_MESSAGE_STREAM_STATUS: {
            GstStreamStatusType type;
            GstElement* owner;
            gst_message_parse_stream_status(msg, &type, &owner);
            const gchar* name = GST_ELEMENT_NAME(owner);
            LOG_VAR("GST-STREAM", "Stream status from ", name);
            break;
        }
        case GST_MESSAGE_LATENCY: {
            LOG("GST-LATENCY", "Latency message received, recalculating...");
            gst_bin_recalculate_latency(GST_BIN(stream->getPipeline()));
            break;
        }
        case GST_MESSAGE_QOS: {
            guint64 running_time, stream_time, timestamp, duration;
            gst_message_parse_qos(msg, NULL, &running_time, &stream_time, &timestamp, &duration);
            LOG("GST-QOS", "QoS event - running_time: " << running_time / GST_MSECOND << "ms");
            break;
        }
        default:
            break;
    }
    return TRUE;
}
// ==================== END DEBUG LOGGING ====================

WebRTCStream::WebRTCStream(const std::string& stream_id)
    : stream_id_(stream_id)
    , pipeline_(nullptr)
    , webrtcbin_(nullptr)
    , is_streaming_(false)
    , audio_input_enabled_(false) {
    LOG_VAR("INIT", "WebRTCStream created: ", stream_id);
}

WebRTCStream::~WebRTCStream() {
    LOG_VAR("DESTROY", "WebRTCStream destroying: ", stream_id_);
    stop();
}

bool WebRTCStream::initialize(const std::string& video_device,
                              const std::string& audio_device,
                              CameraType camera_type) {
    LOG("INIT", "Initializing GStreamer...");
    gst_init(nullptr, nullptr);

    LOG_VAR("INIT", "Video device: ", video_device);
    LOG_VAR("INIT", "Audio device: ", audio_device);
    LOG_VAR("INIT", "Camera type: ", (camera_type == CameraType::CSI ? "CSI" : "USB"));

    return createPipeline(video_device, audio_device, camera_type);
}

bool WebRTCStream::createPipeline(const std::string& video_device,
                                  const std::string& audio_device,
                                  CameraType camera_type) {
    GError* error = nullptr;

    // Build video source based on camera type
    std::string video_source;

    if (camera_type == CameraType::CSI) {
        // Raspberry Pi CSI Camera (OV5647, IMX219, etc.) using libcamera
        // Optimized for the 5MP OV5647 IR Night Vision Camera
        std::cout << "Using CSI camera (libcamerasrc) - Pi Camera Module" << std::endl;
        video_source =
            "libcamerasrc ! "
            "video/x-raw,width=1280,height=720,framerate=30/1,format=NV12 ! "
            "videoconvert ! "
            "video/x-raw,format=I420 ! ";
    } else {
        // USB Camera using v4l2
        std::cout << "Using USB camera (v4l2src) - device: " << video_device << std::endl;
        video_source =
            "v4l2src device=" + video_device + " ! "
            "video/x-raw,width=1280,height=720,framerate=30/1 ! "
            "videoconvert ! "
            "queue max-size-buffers=1 leaky=downstream ! ";
    }

    // Create optimized pipeline for Raspberry Pi
    std::string pipeline_str =
        // Video source (CSI or USB)
        video_source +

        // H264 encoding - continuous streaming with regular keyframes
        "x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=15 bframes=0 ! "
        "h264parse config-interval=1 ! "
        "rtph264pay config-interval=1 pt=96 ! "

        // WebRTC bin
        "application/x-rtp,media=video,encoding-name=H264,payload=96 ! "
        "webrtcbin name=webrtc bundle-policy=max-bundle stun-server=stun://stun.l.google.com:19302 "

        // Audio source
        "alsasrc device=" + audio_device + " ! "
        "audioconvert ! "
        "audioresample ! "
        "audio/x-raw,rate=48000,channels=1 ! "
        "queue max-size-buffers=1 leaky=downstream ! "

        // Opus encoding
        "opusenc bitrate=32000 ! "
        "rtpopuspay pt=97 ! "
        "queue ! "
        "application/x-rtp,media=audio,encoding-name=OPUS,payload=97 ! "
        "webrtc.";
    
    LOG("PIPELINE", "Creating pipeline...");
    LOG("PIPELINE", "Pipeline string: " << pipeline_str.substr(0, 200) << "...");

    pipeline_ = gst_parse_launch(pipeline_str.c_str(), &error);

    if (error) {
        LOG_VAR("PIPELINE-ERROR", "Pipeline creation error: ", error->message);
        g_error_free(error);
        return false;
    }

    // Add bus watch for message monitoring
    GstBus* bus = gst_element_get_bus(pipeline_);
    gst_bus_add_watch(bus, bus_callback, this);
    gst_object_unref(bus);
    LOG("PIPELINE", "Bus watch added for message monitoring");

    // Get webrtcbin element
    webrtcbin_ = gst_bin_get_by_name(GST_BIN(pipeline_), "webrtc");
    if (!webrtcbin_) {
        LOG("PIPELINE-ERROR", "Failed to get webrtcbin element");
        gst_object_unref(pipeline_);
        return false;
    }
    LOG("PIPELINE", "Got webrtcbin element");

    // Connect signals
    g_signal_connect(webrtcbin_, "on-negotiation-needed",
                    G_CALLBACK(onNegotiationNeeded), this);
    g_signal_connect(webrtcbin_, "on-ice-candidate",
                    G_CALLBACK(onIceCandidate), this);
    LOG("PIPELINE", "WebRTC signals connected");

    LOG("PIPELINE", "Pipeline created successfully");
    return true;
}

bool WebRTCStream::start() {
    if (is_streaming_) {
        LOG("START", "Stream already running");
        return true;
    }

    LOG("START", "Setting pipeline to PLAYING state...");
    GstStateChangeReturn ret = gst_element_set_state(pipeline_, GST_STATE_PLAYING);

    if (ret == GST_STATE_CHANGE_FAILURE) {
        LOG("START-ERROR", "Failed to start pipeline - state change failed");
        return false;
    }

    LOG_VAR("START", "State change return: ",
        (ret == GST_STATE_CHANGE_SUCCESS ? "SUCCESS" :
         ret == GST_STATE_CHANGE_ASYNC ? "ASYNC" :
         ret == GST_STATE_CHANGE_NO_PREROLL ? "NO_PREROLL" : "UNKNOWN"));

    is_streaming_ = true;
    LOG_VAR("START", "Stream started: ", stream_id_);
    return true;
}

void WebRTCStream::stop() {
    if (!is_streaming_) {
        LOG("STOP", "Stream not running");
        return;
    }

    LOG("STOP", "Stopping stream...");
    if (pipeline_) {
        LOG("STOP", "Setting pipeline to NULL state");
        gst_element_set_state(pipeline_, GST_STATE_NULL);
        gst_object_unref(pipeline_);
        pipeline_ = nullptr;
    }

    is_streaming_ = false;
    LOG_VAR("STOP", "Stream stopped: ", stream_id_);
}

void WebRTCStream::createOffer(std::function<void(const std::string&)> callback) {
    LOG("OFFER", "Creating WebRTC offer...");
    offer_callback_ = callback;

    // Create offer
    GstPromise* promise = gst_promise_new_with_change_func(onOfferCreated, this, nullptr);
    g_signal_emit_by_name(webrtcbin_, "create-offer", nullptr, promise);
}

void WebRTCStream::onOfferCreated(GstPromise* promise, gpointer user_data) {
    LOG("OFFER", "Offer created callback triggered");
    WebRTCStream* stream = static_cast<WebRTCStream*>(user_data);

    GstWebRTCSessionDescription* offer = nullptr;
    const GstStructure* reply = gst_promise_get_reply(promise);
    gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, nullptr);
    gst_promise_unref(promise);

    if (!offer) {
        LOG("OFFER-ERROR", "Failed to get offer from promise");
        return;
    }

    // Set local description
    LOG("OFFER", "Setting local description...");
    GstPromise* local_promise = gst_promise_new();
    g_signal_emit_by_name(stream->webrtcbin_, "set-local-description", offer, local_promise);
    gst_promise_interrupt(local_promise);
    gst_promise_unref(local_promise);
    LOG("OFFER", "Local description set");

    // Get SDP string
    gchar* sdp_string = gst_sdp_message_as_text(offer->sdp);
    std::string sdp(sdp_string);
    g_free(sdp_string);

    LOG_VAR("OFFER", "SDP offer length: ", sdp.length());
    LOG("OFFER", "SDP offer (first 500 chars): " << sdp.substr(0, 500));

    // Call callback with offer
    if (stream->offer_callback_) {
        LOG("OFFER", "Calling offer callback to send to viewer");
        stream->offer_callback_(sdp);
    }

    gst_webrtc_session_description_free(offer);
}

void WebRTCStream::setRemoteAnswer(const std::string& sdp) {
    LOG_VAR("ANSWER", "Setting remote answer, SDP length: ", sdp.length());
    LOG("ANSWER", "SDP answer (first 500 chars): " << sdp.substr(0, 500));

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
    LOG("ANSWER", "Remote answer set successfully");
}

void WebRTCStream::addIceCandidate(const std::string& candidate, int sdp_mline_index) {
    LOG("ICE", "Adding remote ICE candidate, mlineindex: " << sdp_mline_index);
    LOG_VAR("ICE", "Candidate: ", candidate.substr(0, 80));
    g_signal_emit_by_name(webrtcbin_, "add-ice-candidate", sdp_mline_index, candidate.c_str());
}

void WebRTCStream::onNegotiationNeeded(GstElement* webrtc, gpointer user_data) {
    LOG("WEBRTC", "on-negotiation-needed signal received");
}

void WebRTCStream::onIceCandidate(GstElement* webrtc, guint mlineindex,
                                 gchar* candidate, gpointer user_data) {
    WebRTCStream* stream = static_cast<WebRTCStream*>(user_data);

    std::string cand_str(candidate ? candidate : "");
    LOG("ICE", "Local ICE candidate generated, mlineindex: " << mlineindex);
    if (!cand_str.empty()) {
        LOG_VAR("ICE", "Candidate: ", cand_str.substr(0, 80));
    } else {
        LOG("ICE", "ICE gathering complete (empty candidate)");
    }

    if (stream->ice_candidate_callback_ && !cand_str.empty()) {
        stream->ice_candidate_callback_(cand_str, mlineindex);
    }
}

void WebRTCStream::setIceCandidateCallback(
    std::function<void(const std::string&, int)> callback) {
    LOG("CALLBACK", "ICE candidate callback set");
    ice_candidate_callback_ = callback;
}

void WebRTCStream::enableAudioInput(bool enable) {
    audio_input_enabled_ = enable;
    LOG_VAR("AUDIO", "Audio input ", (enable ? "enabled" : "disabled"));
}
