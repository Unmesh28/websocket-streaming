#include "webrtc_stream.h"
#include <gst/sdp/sdp.h>
#include <iostream>

WebRTCStream::WebRTCStream(const std::string& stream_id)
    : stream_id_(stream_id)
    , pipeline_(nullptr)
    , webrtcbin_(nullptr)
    , is_streaming_(false)
    , audio_input_enabled_(false) {
}

WebRTCStream::~WebRTCStream() {
    stop();
}

bool WebRTCStream::initialize(const std::string& video_device, 
                              const std::string& audio_device) {
    // Initialize GStreamer
    gst_init(nullptr, nullptr);
    
    return createPipeline(video_device, audio_device);
}

bool WebRTCStream::createPipeline(const std::string& video_device,
                                  const std::string& audio_device) {
    GError* error = nullptr;
    
    // Create optimized pipeline for Raspberry Pi
    std::string pipeline_str = 
        // Video source
        "v4l2src device=" + video_device + " ! "
        "video/x-raw,width=1280,height=720,framerate=30/1 ! "
        "videoconvert ! "
        "queue max-size-buffers=1 leaky=downstream ! "
        
        // H264 encoding
        "x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 ! "
        "video/x-h264,profile=baseline ! "
        "h264parse ! "
        "queue ! "
        "rtph264pay config-interval=-1 pt=96 ! "
        "queue ! "
        
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
    
    std::cout << "Creating pipeline..." << std::endl;
    
    pipeline_ = gst_parse_launch(pipeline_str.c_str(), &error);
    
    if (error) {
        std::cerr << "Pipeline creation error: " << error->message << std::endl;
        g_error_free(error);
        return false;
    }
    
    // Get webrtcbin element
    webrtcbin_ = gst_bin_get_by_name(GST_BIN(pipeline_), "webrtc");
    if (!webrtcbin_) {
        std::cerr << "Failed to get webrtcbin element" << std::endl;
        gst_object_unref(pipeline_);
        return false;
    }
    
    // Connect signals
    g_signal_connect(webrtcbin_, "on-negotiation-needed",
                    G_CALLBACK(onNegotiationNeeded), this);
    g_signal_connect(webrtcbin_, "on-ice-candidate",
                    G_CALLBACK(onIceCandidate), this);
    
    std::cout << "Pipeline created successfully" << std::endl;
    return true;
}

bool WebRTCStream::start() {
    if (is_streaming_) {
        return true;
    }
    
    GstStateChangeReturn ret = gst_element_set_state(pipeline_, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        std::cerr << "Failed to start pipeline" << std::endl;
        return false;
    }
    
    is_streaming_ = true;
    std::cout << "Stream started: " << stream_id_ << std::endl;
    return true;
}

void WebRTCStream::stop() {
    if (!is_streaming_) {
        return;
    }
    
    if (pipeline_) {
        gst_element_set_state(pipeline_, GST_STATE_NULL);
        gst_object_unref(pipeline_);
        pipeline_ = nullptr;
    }
    
    is_streaming_ = false;
    std::cout << "Stream stopped: " << stream_id_ << std::endl;
}

void WebRTCStream::createOffer(std::function<void(const std::string&)> callback) {
    offer_callback_ = callback;
    
    // Create offer
    GstPromise* promise = gst_promise_new_with_change_func(onOfferCreated, this, nullptr);
    g_signal_emit_by_name(webrtcbin_, "create-offer", nullptr, promise);
}

void WebRTCStream::onOfferCreated(GstPromise* promise, gpointer user_data) {
    WebRTCStream* stream = static_cast<WebRTCStream*>(user_data);
    
    GstWebRTCSessionDescription* offer = nullptr;
    const GstStructure* reply = gst_promise_get_reply(promise);
    gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, nullptr);
    gst_promise_unref(promise);
    
    // Set local description
    GstPromise* local_promise = gst_promise_new();
    g_signal_emit_by_name(stream->webrtcbin_, "set-local-description", offer, local_promise);
    gst_promise_interrupt(local_promise);
    gst_promise_unref(local_promise);
    
    // Get SDP string
    gchar* sdp_string = gst_sdp_message_as_text(offer->sdp);
    std::string sdp(sdp_string);
    g_free(sdp_string);
    
    // Call callback with offer
    if (stream->offer_callback_) {
        stream->offer_callback_(sdp);
    }
    
    gst_webrtc_session_description_free(offer);
}

void WebRTCStream::setRemoteAnswer(const std::string& sdp) {
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
}

void WebRTCStream::addIceCandidate(const std::string& candidate, int sdp_mline_index) {
    g_signal_emit_by_name(webrtcbin_, "add-ice-candidate", sdp_mline_index, candidate.c_str());
}

void WebRTCStream::onNegotiationNeeded(GstElement* webrtc, gpointer user_data) {
    std::cout << "Negotiation needed" << std::endl;
}

void WebRTCStream::onIceCandidate(GstElement* webrtc, guint mlineindex, 
                                 gchar* candidate, gpointer user_data) {
    WebRTCStream* stream = static_cast<WebRTCStream*>(user_data);
    
    if (stream->ice_candidate_callback_) {
        stream->ice_candidate_callback_(std::string(candidate), mlineindex);
    }
}

void WebRTCStream::setIceCandidateCallback(
    std::function<void(const std::string&, int)> callback) {
    ice_candidate_callback_ = callback;
}

void WebRTCStream::enableAudioInput(bool enable) {
    audio_input_enabled_ = enable;
    std::cout << "Audio input " << (enable ? "enabled" : "disabled") << std::endl;
}
