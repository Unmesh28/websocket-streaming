#ifndef CLOUDFLARE_TURN_H
#define CLOUDFLARE_TURN_H

#include <string>
#include <chrono>
#include <mutex>

/**
 * CloudflareTurn - Fetches short-lived TURN credentials from Cloudflare's API
 *
 * Cloudflare TURN requires dynamic credentials that expire (max 48 hours).
 * This class handles fetching and caching credentials from their REST API.
 *
 * Required environment variables:
 *   CLOUDFLARE_ACCOUNT_ID  - Your Cloudflare account ID
 *   CLOUDFLARE_TURN_KEY_ID - The TURN key ID from Cloudflare Calls dashboard
 *   CLOUDFLARE_API_TOKEN   - API token with Calls permissions
 *
 * Or configure via setConfig() method.
 */
class CloudflareTurn {
public:
    // Configuration for Cloudflare TURN
    struct Config {
        std::string account_id;     // Cloudflare account ID
        std::string turn_key_id;    // TURN key ID from Cloudflare Calls
        std::string api_token;      // API token with Calls:Edit permission
        int ttl_seconds = 86400;    // Credential TTL (default 24 hours, max 48 hours)
    };

    // Fetched credentials
    struct Credentials {
        std::string username;
        std::string password;
        std::string turn_uri;       // turn:turn.cloudflare.com:3478
        std::string turns_uri;      // turns:turn.cloudflare.com:5349
        std::chrono::system_clock::time_point expires_at;
        bool valid = false;
    };

    // Singleton instance
    static CloudflareTurn& instance();

    // Configure Cloudflare TURN (call once at startup)
    void setConfig(const Config& config);

    // Load configuration from environment variables
    bool loadConfigFromEnv();

    // Check if configured
    bool isConfigured() const;

    // Get current credentials (fetches if needed or expired)
    // Returns cached credentials if still valid
    Credentials getCredentials();

    // Force refresh credentials
    Credentials refreshCredentials();

    // Get TURN URI for webrtcbin (includes credentials)
    // Format: turn://username:password@turn.cloudflare.com:3478
    std::string getTurnUri();

private:
    CloudflareTurn() = default;
    ~CloudflareTurn() = default;
    CloudflareTurn(const CloudflareTurn&) = delete;
    CloudflareTurn& operator=(const CloudflareTurn&) = delete;

    // Fetch new credentials from Cloudflare API
    bool fetchCredentials();

    // Parse JSON response
    bool parseResponse(const std::string& json_response);

    Config config_;
    Credentials credentials_;
    bool configured_ = false;
    std::mutex mutex_;

    // Refresh credentials 5 minutes before expiry
    static constexpr int REFRESH_MARGIN_SECONDS = 300;
};

#endif // CLOUDFLARE_TURN_H
