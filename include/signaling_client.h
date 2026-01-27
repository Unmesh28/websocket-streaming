#ifndef SIGNALING_CLIENT_H
#define SIGNALING_CLIENT_H

#include <string>
#include <functional>
#include <memory>
#include <thread>
#include <atomic>
#include <websocketpp/config/asio_client.hpp>
#include <websocketpp/client.hpp>
#include <json/json.h>

typedef websocketpp::client<websocketpp::config::asio_client> WSClient;
typedef websocketpp::connection_hdl ConnectionHdl;

class SignalingClient {
public:
    SignalingClient(const std::string& server_url);
    ~SignalingClient();

    // Connect to signaling server
    bool connect();
    
    // Disconnect
    void disconnect();
    
    // Register as a broadcaster
    bool registerBroadcaster(const std::string& stream_id);
    
    // Send SDP offer to viewer
    void sendOffer(const std::string& viewer_id, const std::string& sdp);
    
    // Send ICE candidate
    void sendIceCandidate(const std::string& peer_id, 
                         const std::string& candidate, int sdp_mline_index);
    
    // Set callbacks
    void setOnViewerJoined(std::function<void(const std::string&)> callback);
    void setOnAnswer(std::function<void(const std::string&, const std::string&)> callback);
    void setOnIceCandidate(std::function<void(const std::string&, const std::string&, int)> callback);
    void setOnViewerLeft(std::function<void(const std::string&)> callback);

private:
    std::string server_url_;
    WSClient client_;
    ConnectionHdl connection_;
    std::thread io_thread_;
    std::atomic<bool> connected_;
    
    std::function<void(const std::string&)> on_viewer_joined_;
    std::function<void(const std::string&, const std::string&)> on_answer_;
    std::function<void(const std::string&, const std::string&, int)> on_ice_candidate_;
    std::function<void(const std::string&)> on_viewer_left_;
    
    // WebSocket callbacks
    void onOpen(ConnectionHdl hdl);
    void onClose(ConnectionHdl hdl);
    void onMessage(ConnectionHdl hdl, WSClient::message_ptr msg);
    void onFail(ConnectionHdl hdl);
    
    // Message handling
    void handleMessage(const std::string& message);
    void sendMessage(const Json::Value& message);
};

#endif // SIGNALING_CLIENT_H
