#ifndef WEBRTC_STREAM_H
#define WEBRTC_STREAM_H

#include <gst/gst.h>
#include <gst/webrtc/webrtc.h>
#include <string>
#include <functional>
#include <memory>

class WebRTCStream {
public:
    WebRTCStream(const std::string& stream_id);
    ~WebRTCStream();

    // Camera types
    enum class CameraType {
        CSI,    // Raspberry Pi Camera Module (CSI interface) - uses libcamerasrc
        USB     // USB Webcam - uses v4l2src
    };

    // Initialize stream with camera and audio
    bool initialize(const std::string& video_device = "/dev/video0",
                   const std::string& audio_device = "default",
                   CameraType camera_type = CameraType::CSI);
    
    // Start streaming
    bool start();
    
    // Stop streaming
    void stop();
    
    // Create offer for WebRTC negotiation
    void createOffer(std::function<void(const std::string&)> callback);
    
    // Handle remote answer
    void setRemoteAnswer(const std::string& sdp);
    
    // Handle ICE candidate
    void addIceCandidate(const std::string& candidate, int sdp_mline_index);
    
    // Set callback for ICE candidates
    void setIceCandidateCallback(std::function<void(const std::string&, int)> callback);
    
    // Enable/disable audio input (for call mode)
    void enableAudioInput(bool enable);
    
    // Get stream ID
    std::string getStreamId() const { return stream_id_; }
    
    // Check if streaming
    bool isStreaming() const { return is_streaming_; }

    // Get pipeline (for debugging/monitoring)
    GstElement* getPipeline() const { return pipeline_; }

private:
    std::string stream_id_;
    GstElement* pipeline_;
    GstElement* webrtcbin_;
    bool is_streaming_;
    bool audio_input_enabled_;
    
    std::function<void(const std::string&, int)> ice_candidate_callback_;
    std::function<void(const std::string&)> offer_callback_;
    
    // GStreamer callbacks
    static void onNegotiationNeeded(GstElement* webrtc, gpointer user_data);
    static void onIceCandidate(GstElement* webrtc, guint mlineindex, 
                              gchar* candidate, gpointer user_data);
    static void onOfferCreated(GstPromise* promise, gpointer user_data);
    
    // Pipeline creation
    bool createPipeline(const std::string& video_device,
                       const std::string& audio_device,
                       CameraType camera_type);
};

#endif // WEBRTC_STREAM_H
