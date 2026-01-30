import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../services/webrtc_service.dart';
import '../widgets/ptt_button.dart';

/// Direct WebRTC screen - Native WebRTC implementation with PTT support
/// This screen uses native WebRTC APIs instead of WebView for better
/// microphone access and control.
class DirectWebRTCScreen extends StatefulWidget {
  final String serverUrl;

  const DirectWebRTCScreen({
    super.key,
    required this.serverUrl,
  });

  @override
  State<DirectWebRTCScreen> createState() => _DirectWebRTCScreenState();
}

class _DirectWebRTCScreenState extends State<DirectWebRTCScreen>
    with WidgetsBindingObserver {
  late WebRTCService _webrtcService;
  late TextEditingController _urlController;
  bool _isFullscreen = false;
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Initialize URL controller with passed URL
    _currentUrl = widget.serverUrl;
    _urlController = TextEditingController(text: widget.serverUrl);

    // Create WebRTC service
    _webrtcService = WebRTCService();

    // Initialize mic FIRST, then connect
    // This ensures audio track is available for SDP negotiation
    _initAndConnect();
  }

  Future<void> _initAndConnect() async {
    // Initialize mic first - wait for it to complete
    debugPrint('[DirectWebRTC] Initializing microphone...');
    final micReady = await _webrtcService.initMicrophone();
    debugPrint('[DirectWebRTC] Microphone initialized: $micReady');

    // Now connect if we have a valid URL
    if (_isValidUrl(widget.serverUrl)) {
      debugPrint('[DirectWebRTC] Auto-connecting to ${widget.serverUrl}');
      _connect();
    }
  }

  bool _isValidUrl(String url) {
    if (url.isEmpty) return false;
    try {
      final uri = Uri.parse(url);
      return uri.host.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  String _normalizeUrl(String url) {
    url = url.trim();
    if (url.isEmpty) return '';

    // Add protocol if missing
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      // Use http for IP addresses
      if (RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(url.split(':')[0])) {
        url = 'http://$url';
      } else {
        url = 'https://$url';
      }
    }
    return url;
  }

  Future<void> _connect() async {
    String url = _normalizeUrl(_urlController.text);

    if (!_isValidUrl(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid server URL'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _currentUrl = url;
    });

    await _webrtcService.connect(url);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _urlController.dispose();
    _webrtcService.disconnect();
    _webrtcService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reconnect if disconnected when app comes back to foreground
      if (!_webrtcService.isConnected && _isValidUrl(_currentUrl)) {
        _webrtcService.connect(_currentUrl);
      }
    }
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
    });

    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _webrtcService,
      child: Consumer<WebRTCService>(
        builder: (context, service, _) {
          return Scaffold(
            backgroundColor: Colors.black,
            appBar: _isFullscreen
                ? null
                : AppBar(
                    title: const Text('Direct WebRTC'),
                    backgroundColor: Colors.black87,
                    foregroundColor: Colors.white,
                    actions: [
                      // Mic status indicator
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              service.micInitialized
                                  ? Icons.mic
                                  : Icons.mic_off,
                              color: service.micInitialized
                                  ? Colors.green
                                  : Colors.grey,
                              size: 20,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              service.micInitialized ? 'Mic Ready' : 'No Mic',
                              style: TextStyle(
                                fontSize: 12,
                                color: service.micInitialized
                                    ? Colors.green
                                    : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Fullscreen button
                      IconButton(
                        icon: const Icon(Icons.fullscreen),
                        onPressed: _toggleFullscreen,
                        tooltip: 'Fullscreen',
                      ),
                      // Refresh button
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: service.isOperationInProgress
                            ? null
                            : () => service.refresh(),
                        tooltip: 'Refresh',
                      ),
                    ],
                  ),
            body: Column(
              children: [
                // URL input bar (when not fullscreen and not connected)
                if (!_isFullscreen && service.connectionState != StreamState.connected)
                  Container(
                    padding: const EdgeInsets.all(8),
                    color: Colors.grey[900],
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _urlController,
                            decoration: InputDecoration(
                              hintText: 'Server URL (e.g., http://3.110.83.74:8080)',
                              filled: true,
                              fillColor: Colors.grey[800],
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              prefixIcon: const Icon(Icons.link, size: 20, color: Colors.white70),
                              hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                            ),
                            style: const TextStyle(color: Colors.white),
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) => _connect(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: service.isOperationInProgress ? null : _connect,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                          ),
                          child: const Text('Connect'),
                        ),
                      ],
                    ),
                  ),

                // Main content
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Video display
                      _buildVideoView(service),

                      // Connection overlay
                      if (service.connectionState != StreamState.connected)
                        _buildConnectionOverlay(service),

                      // Talking indicator
                      if (service.isTalking)
                        Positioned(
                          top: _isFullscreen ? 20 : 10,
                          right: 10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.mic, color: Colors.white, size: 16),
                                SizedBox(width: 4),
                                Text(
                                  'Transmitting...',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // PTT Button
                      if (service.isConnected)
                        Positioned(
                          bottom: _isFullscreen ? 30 : 80,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: PTTButton(
                              enabled: service.micInitialized,
                              isTalking: service.isTalking,
                              onTalkStart: () => service.startTalk(),
                              onTalkEnd: () => service.stopTalk(),
                              onRequestMic: () async {
                                final success = await service.initMicrophone();
                                if (!success && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Microphone permission denied'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              },
                            ),
                          ),
                        ),

                      // Fullscreen exit tap area
                      if (_isFullscreen)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: GestureDetector(
                            onTap: _toggleFullscreen,
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              child: const Icon(
                                Icons.fullscreen_exit,
                                color: Colors.white54,
                                size: 30,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // Status bar at bottom (when not fullscreen)
                if (!_isFullscreen) _buildStatusBar(service),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildVideoView(WebRTCService service) {
    if (service.remoteRenderer == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return RTCVideoView(
      service.remoteRenderer!,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      mirror: false,
    );
  }

  Widget _buildConnectionOverlay(WebRTCService service) {
    IconData icon;
    Color color;
    String message = service.statusMessage;

    switch (service.connectionState) {
      case StreamState.connecting:
        icon = Icons.sync;
        color = Colors.orange;
        break;
      case StreamState.failed:
        icon = Icons.error_outline;
        color = Colors.red;
        break;
      case StreamState.disconnected:
      default:
        icon = Icons.cloud_off;
        color = Colors.grey;
        break;
    }

    return Container(
      color: Colors.black.withOpacity(0.8),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (service.connectionState == StreamState.connecting)
              const CircularProgressIndicator(color: Colors.white)
            else
              Icon(icon, size: 48, color: color),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            if (_currentUrl.isNotEmpty)
              Text(
                _currentUrl,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            if (service.connectionState == StreamState.failed) ...[
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar(WebRTCService service) {
    Color statusColor;
    String statusText;

    switch (service.connectionState) {
      case StreamState.connected:
        statusColor = Colors.green;
        statusText = 'Connected';
        break;
      case StreamState.connecting:
        statusColor = Colors.orange;
        statusText = 'Connecting...';
        break;
      case StreamState.failed:
        statusColor = Colors.red;
        statusText = 'Failed';
        break;
      case StreamState.disconnected:
      default:
        statusColor = Colors.grey;
        statusText = 'Disconnected';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.black.withOpacity(0.7),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Connection status
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              statusText,
              style: TextStyle(color: statusColor, fontSize: 12),
            ),
            const SizedBox(width: 16),

            // ICE state
            Text(
              'ICE: ${service.iceState.isNotEmpty ? service.iceState : '-'}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),

            const Spacer(),

            // Audio/Video toggle buttons
            IconButton(
              icon: Icon(
                service.audioEnabled ? Icons.volume_up : Icons.volume_off,
                color: service.audioEnabled ? Colors.white : Colors.red,
                size: 20,
              ),
              onPressed: () => service.toggleAudio(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Toggle Audio',
            ),
            const SizedBox(width: 16),
            IconButton(
              icon: Icon(
                service.videoEnabled ? Icons.videocam : Icons.videocam_off,
                color: service.videoEnabled ? Colors.white : Colors.red,
                size: 20,
              ),
              onPressed: () => service.toggleVideo(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Toggle Video',
            ),
          ],
        ),
      ),
    );
  }
}
