#include "signaling_client.h"
#include <iostream>

SignalingClient::SignalingClient(const std::string& server_url)
    : server_url_(server_url)
    , connected_(false) {

    // Determine if TLS is needed based on URL scheme
    use_tls_ = (server_url_.substr(0, 6) == "wss://");

    if (use_tls_) {
        // Setup TLS client
        client_tls_.clear_access_channels(websocketpp::log::alevel::all);
        client_tls_.set_access_channels(websocketpp::log::alevel::connect);
        client_tls_.set_access_channels(websocketpp::log::alevel::disconnect);
        client_tls_.set_error_channels(websocketpp::log::elevel::all);

        client_tls_.init_asio();

        client_tls_.set_open_handler([this](ConnectionHdl hdl) { onOpen(hdl); });
        client_tls_.set_close_handler([this](ConnectionHdl hdl) { onClose(hdl); });
        client_tls_.set_message_handler([this](ConnectionHdl hdl, WSClientTLS::message_ptr msg) {
            onMessageTLS(hdl, msg);
        });
        client_tls_.set_fail_handler([this](ConnectionHdl hdl) { onFail(hdl); });
        client_tls_.set_tls_init_handler([this](ConnectionHdl hdl) { return onTlsInit(hdl); });

        std::cout << "Using secure WebSocket (wss://)" << std::endl;
    } else {
        // Setup non-TLS client
        client_no_tls_.clear_access_channels(websocketpp::log::alevel::all);
        client_no_tls_.set_access_channels(websocketpp::log::alevel::connect);
        client_no_tls_.set_access_channels(websocketpp::log::alevel::disconnect);
        client_no_tls_.set_error_channels(websocketpp::log::elevel::all);

        client_no_tls_.init_asio();

        client_no_tls_.set_open_handler([this](ConnectionHdl hdl) { onOpen(hdl); });
        client_no_tls_.set_close_handler([this](ConnectionHdl hdl) { onClose(hdl); });
        client_no_tls_.set_message_handler([this](ConnectionHdl hdl, WSClientNoTLS::message_ptr msg) {
            onMessageNoTLS(hdl, msg);
        });
        client_no_tls_.set_fail_handler([this](ConnectionHdl hdl) { onFail(hdl); });

        std::cout << "Using plain WebSocket (ws://)" << std::endl;
    }
}

SignalingClient::~SignalingClient() {
    disconnect();
}

bool SignalingClient::connect() {
    try {
        websocketpp::lib::error_code ec;

        if (use_tls_) {
            WSClientTLS::connection_ptr con = client_tls_.get_connection(server_url_, ec);

            if (ec) {
                std::cerr << "Connection error: " << ec.message() << std::endl;
                return false;
            }

            connection_ = con->get_handle();
            client_tls_.connect(con);

            io_thread_ = std::thread([this]() {
                client_tls_.run();
            });
        } else {
            WSClientNoTLS::connection_ptr con = client_no_tls_.get_connection(server_url_, ec);

            if (ec) {
                std::cerr << "Connection error: " << ec.message() << std::endl;
                return false;
            }

            connection_ = con->get_handle();
            client_no_tls_.connect(con);

            io_thread_ = std::thread([this]() {
                client_no_tls_.run();
            });
        }

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
        if (use_tls_) {
            client_tls_.close(connection_, websocketpp::close::status::normal, "");
        } else {
            client_no_tls_.close(connection_, websocketpp::close::status::normal, "");
        }
        connected_ = false;
    }

    if (io_thread_.joinable()) {
        if (use_tls_) {
            client_tls_.stop();
        } else {
            client_no_tls_.stop();
        }
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

void SignalingClient::onMessageTLS(ConnectionHdl hdl, WSClientTLS::message_ptr msg) {
    handleMessage(msg->get_payload());
}

void SignalingClient::onMessageNoTLS(ConnectionHdl hdl, WSClientNoTLS::message_ptr msg) {
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
        if (use_tls_) {
            client_tls_.send(connection_, msg_str, websocketpp::frame::opcode::text);
        } else {
            client_no_tls_.send(connection_, msg_str, websocketpp::frame::opcode::text);
        }
    } catch (const std::exception& e) {
        std::cerr << "Send error: " << e.what() << std::endl;
    }
}

std::shared_ptr<boost::asio::ssl::context> SignalingClient::onTlsInit(ConnectionHdl hdl) {
    auto ctx = std::make_shared<boost::asio::ssl::context>(boost::asio::ssl::context::tlsv12);

    try {
        ctx->set_options(boost::asio::ssl::context::default_workarounds |
                        boost::asio::ssl::context::no_sslv2 |
                        boost::asio::ssl::context::no_sslv3 |
                        boost::asio::ssl::context::single_dh_use);

        ctx->set_verify_mode(boost::asio::ssl::verify_none);
    } catch (const std::exception& e) {
        std::cerr << "TLS init error: " << e.what() << std::endl;
    }

    return ctx;
}
