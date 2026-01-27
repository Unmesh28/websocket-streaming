#include "signaling_client.h"
#include <iostream>

SignalingClient::SignalingClient(const std::string& server_url)
    : server_url_(server_url)
    , connected_(false) {
    
    // Set logging
    client_.clear_access_channels(websocketpp::log::alevel::all);
    client_.set_access_channels(websocketpp::log::alevel::connect);
    client_.set_access_channels(websocketpp::log::alevel::disconnect);
    client_.set_error_channels(websocketpp::log::elevel::all);
    
    // Initialize ASIO
    client_.init_asio();
    
    // Set handlers
    client_.set_open_handler([this](ConnectionHdl hdl) { onOpen(hdl); });
    client_.set_close_handler([this](ConnectionHdl hdl) { onClose(hdl); });
    client_.set_message_handler([this](ConnectionHdl hdl, WSClient::message_ptr msg) {
        onMessage(hdl, msg);
    });
    client_.set_fail_handler([this](ConnectionHdl hdl) { onFail(hdl); });
}

SignalingClient::~SignalingClient() {
    disconnect();
}

bool SignalingClient::connect() {
    try {
        websocketpp::lib::error_code ec;
        WSClient::connection_ptr con = client_.get_connection(server_url_, ec);
        
        if (ec) {
            std::cerr << "Connection error: " << ec.message() << std::endl;
            return false;
        }
        
        connection_ = con->get_handle();
        client_.connect(con);
        
        // Run in separate thread
        io_thread_ = std::thread([this]() {
            client_.run();
        });
        
        // Wait for connection
        int retry = 0;
        while (!connected_ && retry < 50) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            retry++;
        }
        
        return connected_;
        
    } catch (const std::exception& e) {
        std::cerr << "Connect exception: " << e.what() << std::endl;
        return false;
    }
}

void SignalingClient::disconnect() {
    if (connected_) {
        client_.close(connection_, websocketpp::close::status::normal, "");
        connected_ = false;
    }
    
    if (io_thread_.joinable()) {
        client_.stop();
        io_thread_.join();
    }
}

bool SignalingClient::registerBroadcaster(const std::string& stream_id) {
    Json::Value msg;
    msg["type"] = "register";
    msg["role"] = "broadcaster";
    msg["stream_id"] = stream_id;
    
    sendMessage(msg);
    return true;
}

void SignalingClient::sendOffer(const std::string& viewer_id, const std::string& sdp) {
    Json::Value msg;
    msg["type"] = "offer";
    msg["to"] = viewer_id;
    msg["sdp"] = sdp;
    
    sendMessage(msg);
}

void SignalingClient::sendIceCandidate(const std::string& peer_id,
                                      const std::string& candidate, 
                                      int sdp_mline_index) {
    Json::Value msg;
    msg["type"] = "ice-candidate";
    msg["to"] = peer_id;
    msg["candidate"] = candidate;
    msg["sdpMLineIndex"] = sdp_mline_index;
    
    sendMessage(msg);
}

void SignalingClient::setOnViewerJoined(std::function<void(const std::string&)> callback) {
    on_viewer_joined_ = callback;
}

void SignalingClient::setOnAnswer(std::function<void(const std::string&, const std::string&)> callback) {
    on_answer_ = callback;
}

void SignalingClient::setOnIceCandidate(std::function<void(const std::string&, const std::string&, int)> callback) {
    on_ice_candidate_ = callback;
}

void SignalingClient::setOnViewerLeft(std::function<void(const std::string&)> callback) {
    on_viewer_left_ = callback;
}

void SignalingClient::onOpen(ConnectionHdl hdl) {
    std::cout << "WebSocket connected" << std::endl;
    connected_ = true;
}

void SignalingClient::onClose(ConnectionHdl hdl) {
    std::cout << "WebSocket disconnected" << std::endl;
    connected_ = false;
}

void SignalingClient::onMessage(ConnectionHdl hdl, WSClient::message_ptr msg) {
    handleMessage(msg->get_payload());
}

void SignalingClient::onFail(ConnectionHdl hdl) {
    std::cerr << "WebSocket connection failed" << std::endl;
    connected_ = false;
}

void SignalingClient::handleMessage(const std::string& message) {
    Json::Value root;
    Json::CharReaderBuilder builder;
    std::istringstream stream(message);
    std::string errs;
    
    if (!Json::parseFromStream(builder, stream, &root, &errs)) {
        std::cerr << "Failed to parse message: " << errs << std::endl;
        return;
    }
    
    std::string type = root["type"].asString();
    
    if (type == "viewer-joined") {
        std::string viewer_id = root["viewer_id"].asString();
        if (on_viewer_joined_) {
            on_viewer_joined_(viewer_id);
        }
    }
    else if (type == "answer") {
        std::string from = root["from"].asString();
        std::string sdp = root["sdp"].asString();
        if (on_answer_) {
            on_answer_(from, sdp);
        }
    }
    else if (type == "ice-candidate") {
        std::string from = root["from"].asString();
        std::string candidate = root["candidate"].asString();
        int sdp_mline_index = root["sdpMLineIndex"].asInt();
        if (on_ice_candidate_) {
            on_ice_candidate_(from, candidate, sdp_mline_index);
        }
    }
    else if (type == "viewer-left") {
        std::string viewer_id = root["viewer_id"].asString();
        if (on_viewer_left_) {
            on_viewer_left_(viewer_id);
        }
    }
}

void SignalingClient::sendMessage(const Json::Value& message) {
    Json::StreamWriterBuilder builder;
    std::string msg_str = Json::writeString(builder, message);
    
    try {
        client_.send(connection_, msg_str, websocketpp::frame::opcode::text);
    } catch (const std::exception& e) {
        std::cerr << "Send error: " << e.what() << std::endl;
    }
}
