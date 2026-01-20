#include "cloudflare_turn.h"
#include <curl/curl.h>
#include <json/json.h>
#include <iostream>
#include <sstream>
#include <cstdlib>
#include <fstream>
#include <vector>

// Callback for libcurl to write response data
static size_t WriteCallback(void* contents, size_t size, size_t nmemb, std::string* userp) {
    userp->append((char*)contents, size * nmemb);
    return size * nmemb;
}

CloudflareTurn& CloudflareTurn::instance() {
    static CloudflareTurn instance;
    return instance;
}

void CloudflareTurn::setConfig(const Config& config) {
    std::lock_guard<std::mutex> lock(mutex_);
    config_ = config;
    configured_ = !config.turn_key_id.empty() && !config.api_token.empty();

    if (configured_) {
        std::cout << "[CLOUDFLARE] TURN configured with key ID: "
                  << config.turn_key_id.substr(0, 8) << "..." << std::endl;
    }
}

bool CloudflareTurn::loadConfigFromEnv() {
    Config config;

    // Try to load from .env file - check multiple locations
    std::vector<std::string> env_paths = {
        ".env",           // Current directory
        "../.env",        // Parent directory (when running from build/)
        "../../.env",     // Two levels up
    };

    bool found_env = false;
    for (const auto& path : env_paths) {
        std::ifstream env_file(path);
        if (env_file.is_open()) {
            std::cout << "[CLOUDFLARE] Loading config from: " << path << std::endl;
            found_env = true;
            std::string line;
            while (std::getline(env_file, line)) {
                // Skip comments and empty lines
                if (line.empty() || line[0] == '#') continue;

                size_t eq_pos = line.find('=');
                if (eq_pos != std::string::npos) {
                    std::string key = line.substr(0, eq_pos);
                    std::string value = line.substr(eq_pos + 1);

                    // Remove quotes if present
                    if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
                        value = value.substr(1, value.size() - 2);
                    }
                    // Also handle single quotes
                    if (value.size() >= 2 && value.front() == '\'' && value.back() == '\'') {
                        value = value.substr(1, value.size() - 2);
                    }

                    if (key == "CLOUDFLARE_ACCOUNT_ID") config.account_id = value;
                    else if (key == "CLOUDFLARE_TURN_KEY_ID") config.turn_key_id = value;
                    else if (key == "CLOUDFLARE_API_TOKEN") config.api_token = value;
                    else if (key == "CLOUDFLARE_TURN_TTL") {
                        try { config.ttl_seconds = std::stoi(value); } catch (...) {}
                    }
                }
            }
            env_file.close();
            break;  // Stop after first found file
        }
    }

    if (!found_env) {
        std::cout << "[CLOUDFLARE] No .env file found in search paths" << std::endl;
    }

    // Override with environment variables if set
    const char* account_id = std::getenv("CLOUDFLARE_ACCOUNT_ID");
    const char* turn_key_id = std::getenv("CLOUDFLARE_TURN_KEY_ID");
    const char* api_token = std::getenv("CLOUDFLARE_API_TOKEN");
    const char* ttl = std::getenv("CLOUDFLARE_TURN_TTL");

    if (account_id && account_id[0]) config.account_id = account_id;
    if (turn_key_id && turn_key_id[0]) config.turn_key_id = turn_key_id;
    if (api_token && api_token[0]) config.api_token = api_token;
    if (ttl && ttl[0]) {
        try { config.ttl_seconds = std::stoi(ttl); } catch (...) {}
    }

    // Validate required fields
    if (config.turn_key_id.empty() || config.api_token.empty()) {
        std::cerr << "[CLOUDFLARE] Missing required configuration:" << std::endl;
        if (config.turn_key_id.empty()) std::cerr << "  - CLOUDFLARE_TURN_KEY_ID" << std::endl;
        if (config.api_token.empty()) std::cerr << "  - CLOUDFLARE_API_TOKEN" << std::endl;
        return false;
    }

    setConfig(config);
    return true;
}

bool CloudflareTurn::isConfigured() const {
    return configured_;
}

CloudflareTurn::Credentials CloudflareTurn::getCredentials() {
    std::lock_guard<std::mutex> lock(mutex_);

    // Check if we have valid cached credentials
    if (credentials_.valid) {
        auto now = std::chrono::system_clock::now();
        auto time_until_expiry = std::chrono::duration_cast<std::chrono::seconds>(
            credentials_.expires_at - now).count();

        // Refresh if less than 5 minutes until expiry
        if (time_until_expiry > REFRESH_MARGIN_SECONDS) {
            return credentials_;
        }
        std::cout << "[CLOUDFLARE] Credentials expiring soon, refreshing..." << std::endl;
    }

    // Fetch new credentials
    if (fetchCredentials()) {
        return credentials_;
    }

    // Return invalid credentials on failure
    return Credentials{};
}

CloudflareTurn::Credentials CloudflareTurn::refreshCredentials() {
    std::lock_guard<std::mutex> lock(mutex_);
    credentials_.valid = false;

    if (fetchCredentials()) {
        return credentials_;
    }
    return Credentials{};
}

bool CloudflareTurn::fetchCredentials() {
    if (!configured_) {
        std::cerr << "[CLOUDFLARE] Not configured, cannot fetch credentials" << std::endl;
        return false;
    }

    std::cout << "[CLOUDFLARE] Fetching TURN credentials from Cloudflare..." << std::endl;

    CURL* curl = curl_easy_init();
    if (!curl) {
        std::cerr << "[CLOUDFLARE] Failed to initialize curl" << std::endl;
        return false;
    }

    // Build URL - Using Cloudflare's RTC endpoint
    // https://rtc.live.cloudflare.com/v1/turn/keys/{key_id}/credentials/generate-ice-servers
    std::string url = "https://rtc.live.cloudflare.com/v1/turn/keys/" +
                      config_.turn_key_id + "/credentials/generate-ice-servers";

    // Build request body
    Json::Value request_body;
    request_body["ttl"] = config_.ttl_seconds;
    Json::StreamWriterBuilder writer;
    std::string body = Json::writeString(writer, request_body);

    // Response buffer
    std::string response;

    // Set up headers
    struct curl_slist* headers = nullptr;
    std::string auth_header = "Authorization: Bearer " + config_.api_token;
    headers = curl_slist_append(headers, auth_header.c_str());
    headers = curl_slist_append(headers, "Content-Type: application/json");

    // Configure curl
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);  // 10 second timeout

    // Perform request
    CURLcode res = curl_easy_perform(curl);

    // Get HTTP status code
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    // Cleanup
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) {
        std::cerr << "[CLOUDFLARE] curl failed: " << curl_easy_strerror(res) << std::endl;
        return false;
    }

    if (http_code != 200) {
        std::cerr << "[CLOUDFLARE] API returned HTTP " << http_code << std::endl;
        std::cerr << "[CLOUDFLARE] Response: " << response << std::endl;
        return false;
    }

    // Parse response
    return parseResponse(response);
}

bool CloudflareTurn::parseResponse(const std::string& json_response) {
    Json::Value root;
    Json::CharReaderBuilder reader;
    std::string errors;
    std::istringstream stream(json_response);

    if (!Json::parseFromStream(reader, stream, &root, &errors)) {
        std::cerr << "[CLOUDFLARE] Failed to parse JSON: " << errors << std::endl;
        return false;
    }

    // Response format:
    // {
    //   "iceServers": [
    //     {
    //       "urls": ["stun:...", "turn:...", "turns:..."],
    //       "username": "xxx",
    //       "credential": "yyy"
    //     }
    //   ]
    // }

    if (!root.isMember("iceServers") || !root["iceServers"].isArray() ||
        root["iceServers"].empty()) {
        std::cerr << "[CLOUDFLARE] Invalid response format - no iceServers" << std::endl;
        std::cerr << "[CLOUDFLARE] Response: " << json_response << std::endl;
        return false;
    }

    const Json::Value& ice_server = root["iceServers"][0];

    if (!ice_server.isMember("username") || !ice_server.isMember("credential")) {
        std::cerr << "[CLOUDFLARE] Missing username/credential in response" << std::endl;
        return false;
    }

    credentials_.username = ice_server["username"].asString();
    credentials_.password = ice_server["credential"].asString();

    // Extract URLs
    if (ice_server.isMember("urls") && ice_server["urls"].isArray()) {
        for (const auto& url : ice_server["urls"]) {
            std::string url_str = url.asString();
            if (url_str.find("turn:") == 0 && url_str.find("turns:") != 0) {
                // Prefer UDP TURN
                if (url_str.find("transport=udp") != std::string::npos ||
                    url_str.find("transport=") == std::string::npos) {
                    credentials_.turn_uri = url_str;
                }
            } else if (url_str.find("turns:") == 0) {
                credentials_.turns_uri = url_str;
            }
        }
    }

    // Set default URIs if not found
    if (credentials_.turn_uri.empty()) {
        credentials_.turn_uri = "turn:turn.cloudflare.com:3478";
    }
    if (credentials_.turns_uri.empty()) {
        credentials_.turns_uri = "turns:turn.cloudflare.com:5349";
    }

    // Set expiry time
    credentials_.expires_at = std::chrono::system_clock::now() +
                              std::chrono::seconds(config_.ttl_seconds);
    credentials_.valid = true;

    std::cout << "[CLOUDFLARE] Credentials fetched successfully!" << std::endl;
    std::cout << "[CLOUDFLARE] TURN URI: " << credentials_.turn_uri << std::endl;
    std::cout << "[CLOUDFLARE] Username: " << credentials_.username.substr(0, 20) << "..." << std::endl;
    std::cout << "[CLOUDFLARE] Valid for: " << config_.ttl_seconds << " seconds" << std::endl;

    return true;
}

std::string CloudflareTurn::getTurnUri() {
    auto creds = getCredentials();
    if (!creds.valid) {
        return "";
    }

    // Build URI with embedded credentials for GStreamer webrtcbin
    // Format: turn://username:password@server:port
    std::string uri = creds.turn_uri;

    // Parse the turn: URI and insert credentials
    // Input: turn:turn.cloudflare.com:3478?transport=udp
    // Output: turn://username:password@turn.cloudflare.com:3478?transport=udp

    size_t colon_pos = uri.find(':');
    if (colon_pos != std::string::npos) {
        std::string scheme = uri.substr(0, colon_pos);  // "turn" or "turns"
        std::string rest = uri.substr(colon_pos + 1);   // "turn.cloudflare.com:3478..."

        // Remove any leading slashes
        while (!rest.empty() && rest[0] == '/') {
            rest = rest.substr(1);
        }

        uri = scheme + "://" + creds.username + ":" + creds.password + "@" + rest;
    }

    return uri;
}
