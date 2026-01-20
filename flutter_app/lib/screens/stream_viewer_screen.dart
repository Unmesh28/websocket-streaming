import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../services/webrtc_service.dart';
import '../widgets/control_button.dart';
import '../widgets/connection_status.dart';

class StreamViewerScreen extends StatefulWidget {
  const StreamViewerScreen({super.key});

  @override
  State<StreamViewerScreen> createState() => _StreamViewerScreenState();
}

class _StreamViewerScreenState extends State<StreamViewerScreen> {
  final TextEditingController _urlController = TextEditingController();
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    // Default URL - can be changed by user
    _urlController.text = 'https://';
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _toggleFullscreen() {
    setState(() {
      _showControls = !_showControls;
    });

    if (!_showControls) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _showControls
          ? AppBar(
              title: const Text('Pi Camera Viewer'),
              backgroundColor: Colors.black87,
              actions: [
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  onPressed: _toggleFullscreen,
                  tooltip: 'Toggle fullscreen',
                ),
              ],
            )
          : null,
      body: SafeArea(
        child: GestureDetector(
          onTap: _toggleFullscreen,
          child: Column(
            children: [
              // Video display area
              Expanded(
                child: _buildVideoView(),
              ),

              // Controls (hidden in fullscreen)
              if (_showControls) ...[
                _buildConnectionPanel(),
                _buildMediaControls(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoView() {
    return Consumer<WebRTCService>(
      builder: (context, service, _) {
        final renderer = service.remoteRenderer;
        final hasVideo = renderer != null && service.isConnected;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Video renderer
            Container(
              color: Colors.black,
              child: hasVideo
                  ? RTCVideoView(
                      renderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            service.connectionState == StreamState.connecting
                                ? Icons.sync
                                : Icons.videocam_off,
                            size: 64,
                            color: Colors.grey,
                          ),
                          if (service.connectionState == StreamState.connecting)
                            const Padding(
                              padding: EdgeInsets.only(top: 16),
                              child: CircularProgressIndicator(
                                color: Colors.blue,
                              ),
                            ),
                        ],
                      ),
                    ),
            ),

            // Connection status overlay
            Positioned(
              top: 16,
              left: 16,
              child: ConnectionStatus(
                state: service.connectionState,
                message: service.statusMessage,
                iceState: service.iceState,
              ),
            ),

            // Tap hint when in fullscreen
            if (!_showControls)
              const Positioned(
                bottom: 16,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(
                    'Tap to show controls',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildConnectionPanel() {
    return Consumer<WebRTCService>(
      builder: (context, service, _) {
        // Use the operation flag to properly disable buttons during connect/disconnect
        final isOperationInProgress = service.isOperationInProgress;
        final isConnecting = service.connectionState == StreamState.connecting;

        return Container(
          padding: const EdgeInsets.all(16),
          color: Colors.black87,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // URL input - disabled during any operation
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'Stream URL',
                  hintText: 'https://your-tunnel-url.com',
                  prefixIcon: const Icon(Icons.link),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: Colors.grey[900],
                ),
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.url,
                enabled: !isOperationInProgress,
              ),

              const SizedBox(height: 12),

              // Connect/Disconnect button
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      // Disable during any operation
                      onPressed: isOperationInProgress
                          ? null
                          : () {
                              if (service.isConnected) {
                                service.disconnect();
                              } else {
                                final url = _urlController.text.trim();
                                if (url.isNotEmpty) {
                                  service.connect(url);
                                }
                              }
                            },
                      icon: isConnecting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              service.isConnected
                                  ? Icons.stop
                                  : Icons.play_arrow,
                            ),
                      label: Text(
                        isConnecting
                            ? 'Connecting...'
                            : service.isConnected
                                ? 'Disconnect'
                                : 'Connect',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: service.isConnected
                            ? Colors.red
                            : Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),

                  const SizedBox(width: 12),

                  // Refresh button - disabled during operations
                  ElevatedButton.icon(
                    onPressed: !isOperationInProgress &&
                              (service.isConnected ||
                               service.connectionState == StreamState.failed)
                        ? () => service.refresh()
                        : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMediaControls() {
    return Consumer<WebRTCService>(
      builder: (context, service, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Colors.black,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Audio toggle
              ControlButton(
                icon: service.audioEnabled
                    ? Icons.volume_up
                    : Icons.volume_off,
                label: 'Audio',
                isEnabled: service.audioEnabled,
                onPressed: service.isConnected
                    ? () => service.toggleAudio()
                    : null,
              ),

              // Video toggle
              ControlButton(
                icon: service.videoEnabled
                    ? Icons.videocam
                    : Icons.videocam_off,
                label: 'Video',
                isEnabled: service.videoEnabled,
                onPressed: service.isConnected
                    ? () => service.toggleVideo()
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }
}
