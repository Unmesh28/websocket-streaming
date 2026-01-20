import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;

enum StreamState {
  disconnected,
  connecting,
  connected,
  failed,
}

class WebRTCService extends ChangeNotifier {
  WebSocketChannel? _channel;
  RTCPeerConnection? _peerConnection;
  RTCVideoRenderer? _remoteRenderer;
  MediaStream? _remoteStream;
  StreamSubscription? _channelSubscription;

  StreamState _connectionState = StreamState.disconnected;
  String _statusMessage = 'Disconnected';
  String _iceState = '';

  bool _audioEnabled = true;
  bool _videoEnabled = true;

  String? _currentUrl;
  String? _currentStreamId;
  String? _viewerId;
  String? _broadcasterId;
  List<Map<String, dynamic>>? _iceServers;

  // Queue for ICE candidates
  final List<Map<String, dynamic>> _pendingIceCandidates = [];
  bool _remoteDescriptionSet = false;

  // Connection management
  bool _isConnecting = false;
  bool _isDisconnecting = false;
  Completer<void>? _cleanupCompleter;

  // Getters
  StreamState get connectionState => _connectionState;
  String get statusMessage => _statusMessage;
  String get iceState => _iceState;
  bool get audioEnabled => _audioEnabled;
  bool get videoEnabled => _videoEnabled;
  RTCVideoRenderer? get remoteRenderer => _remoteRenderer;
  bool get isConnected => _connectionState == StreamState.connected;

  WebRTCService() {
    _initRenderer();
  }

  Future<void> _initRenderer() async {
    _remoteRenderer = RTCVideoRenderer();
    await _remoteRenderer!.initialize();
  }

  void _updateState(StreamState state, String message) {
    if (_connectionState == state && _statusMessage == message) return;
    _connectionState = state;
    _statusMessage = message;
    debugPrint('[WebRTC] State: $state - $message');
    notifyListeners();
  }

  void _updateIceState(String state) {
    if (_iceState == state) return;
    _iceState = state;
    notifyListeners();
  }

  /// Main connect method - handles all connection logic
  Future<bool> connect(String serverUrl, {String streamId = 'pi-camera-stream'}) async {
    // Prevent multiple simultaneous connection attempts
    if (_isConnecting) {
      debugPrint('[WebRTC] Already connecting, ignoring...');
      return false;
    }

    // If already connected to same URL, return success
    if (_connectionState == StreamState.connected &&
        _currentUrl == serverUrl &&
        _currentStreamId == streamId) {
      debugPrint('[WebRTC] Already connected to this stream');
      return true;
    }

    _isConnecting = true;

    try {
      // Clean up any existing connection first
      await _cleanupInternal();

      _currentUrl = serverUrl;
      _currentStreamId = streamId;
      _remoteDescriptionSet = false;
      _pendingIceCandidates.clear();

      _updateState(StreamState.connecting, 'Connecting...');

      // Fetch TURN credentials
      await _fetchTurnCredentials(serverUrl);

      // Connect WebSocket
      final wsUrl = _getWebSocketUrl(serverUrl);
      _updateState(StreamState.connecting, 'Connecting to server...');
      debugPrint('[WebRTC] Connecting to WebSocket: $wsUrl');

      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Set up WebSocket listener
      _channelSubscription = _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          debugPrint('[WebRTC] WebSocket error: $error');
          if (_connectionState != StreamState.disconnected) {
            _updateState(StreamState.failed, 'Connection error');
          }
        },
        onDone: () {
          debugPrint('[WebRTC] WebSocket closed');
          if (_connectionState != StreamState.disconnected && !_isDisconnecting) {
            _updateState(StreamState.disconnected, 'Connection closed');
          }
        },
        cancelOnError: false,
      );

      // Wait for WebSocket to be ready
      await Future.delayed(const Duration(milliseconds: 200));

      // Check if we're still supposed to be connecting
      if (_connectionState != StreamState.connecting) {
        debugPrint('[WebRTC] Connection cancelled');
        return false;
      }

      // Join stream
      final joinMsg = {'type': 'join', 'stream_id': streamId};
      debugPrint('[WebRTC] Sending join: $joinMsg');
      _send(joinMsg);
      _updateState(StreamState.connecting, 'Joining stream...');

      // Wait for connection with timeout
      final connected = await _waitForConnection(timeout: const Duration(seconds: 15));
      return connected;

    } catch (e) {
      debugPrint('[WebRTC] Connection failed: $e');
      _updateState(StreamState.failed, 'Connection failed: $e');
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  /// Wait for connection to be established
  Future<bool> _waitForConnection({required Duration timeout}) async {
    final startTime = DateTime.now();

    while (DateTime.now().difference(startTime) < timeout) {
      if (_connectionState == StreamState.connected) {
        return true;
      }
      if (_connectionState == StreamState.failed ||
          _connectionState == StreamState.disconnected) {
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Timeout
    if (_connectionState == StreamState.connecting) {
      _updateState(StreamState.failed, 'Connection timeout');
    }
    return false;
  }

  Future<void> _fetchTurnCredentials(String serverUrl) async {
    try {
      final httpUrl = serverUrl
          .replaceFirst('wss://', 'https://')
          .replaceFirst('ws://', 'http://');

      final response = await http.get(
        Uri.parse('$httpUrl/turn-credentials'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final rawServers = List<Map<String, dynamic>>.from(data['iceServers']);

        // Normalize ICE servers
        _iceServers = [];
        for (var server in rawServers) {
          final urls = server['urls'];
          final username = server['username'];
          final credential = server['credential'];

          if (urls is List) {
            for (var url in urls) {
              final entry = <String, dynamic>{'urls': url};
              if (username != null) entry['username'] = username;
              if (credential != null) entry['credential'] = credential;
              _iceServers!.add(entry);
            }
          } else {
            _iceServers!.add(Map<String, dynamic>.from(server));
          }
        }

        debugPrint('[WebRTC] Got ${_iceServers!.length} ICE servers');
      }
    } catch (e) {
      debugPrint('[WebRTC] Failed to fetch TURN credentials: $e');
      _iceServers = [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun.cloudflare.com:3478'},
      ];
    }
  }

  String _getWebSocketUrl(String url) {
    url = url.trim();
    if (url.startsWith('https://')) {
      return url.replaceFirst('https://', 'wss://');
    } else if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'ws://');
    } else if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      return 'wss://$url';
    }
    return url;
  }

  void _send(Map<String, dynamic> message) {
    if (_channel == null) {
      debugPrint('[WebRTC] Cannot send - no channel');
      return;
    }
    try {
      final jsonStr = json.encode(message);
      debugPrint('[WebRTC] Sending: ${message['type']}');
      _channel!.sink.add(jsonStr);
    } catch (e) {
      debugPrint('[WebRTC] Send error: $e');
    }
  }

  void _onMessage(dynamic message) {
    if (_isDisconnecting) return;

    try {
      final data = json.decode(message as String);
      final type = data['type'] as String?;
      debugPrint('[WebRTC] Received: $type');

      switch (type) {
        case 'joined':
          _handleJoined(data);
          break;
        case 'offer':
          _handleOffer(data);
          break;
        case 'ice-candidate':
          _handleIceCandidate(data);
          break;
        case 'error':
          _handleError(data);
          break;
        case 'broadcaster-left':
        case 'streamer-disconnected':
          _updateState(StreamState.disconnected, 'Streamer disconnected');
          break;
      }
    } catch (e) {
      debugPrint('[WebRTC] Error parsing message: $e');
    }
  }

  void _handleJoined(Map<String, dynamic> data) {
    _viewerId = data['viewer_id'] as String?;
    _broadcasterId = data['stream_id'] as String?;
    debugPrint('[WebRTC] Joined as $_viewerId, broadcaster: $_broadcasterId');
    _updateState(StreamState.connecting, 'Waiting for stream...');
  }

  void _handleError(Map<String, dynamic> data) {
    final message = data['message'] as String? ?? 'Unknown error';
    debugPrint('[WebRTC] Server error: $message');
    _updateState(StreamState.failed, message);
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    if (_isDisconnecting) return;

    debugPrint('[WebRTC] Received offer');
    _broadcasterId = data['from'] as String? ?? _broadcasterId;
    _updateState(StreamState.connecting, 'Setting up connection...');

    try {
      // Close existing peer connection if any
      if (_peerConnection != null) {
        await _peerConnection!.close();
        _peerConnection = null;
      }

      final iceServers = _iceServers ?? [{'urls': 'stun:stun.l.google.com:19302'}];

      final config = <String, dynamic>{
        'iceServers': iceServers,
        'sdpSemantics': 'unified-plan',
        'iceTransportPolicy': 'all',
      };

      _peerConnection = await createPeerConnection(config);
      debugPrint('[WebRTC] Peer connection created');

      // Set up handlers
      _setupPeerConnectionHandlers();

      // Set remote description
      final offer = RTCSessionDescription(data['sdp'] as String, 'offer');
      await _peerConnection!.setRemoteDescription(offer);
      _remoteDescriptionSet = true;
      debugPrint('[WebRTC] Remote description set');

      // Process queued candidates
      await _processQueuedIceCandidates();

      // Create answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      debugPrint('[WebRTC] Answer created');

      _send({
        'type': 'answer',
        'to': _broadcasterId,
        'sdp': answer.sdp,
      });

      _updateState(StreamState.connecting, 'Establishing connection...');

    } catch (e) {
      debugPrint('[WebRTC] Failed to handle offer: $e');
      _updateState(StreamState.failed, 'Setup failed');
    }
  }

  void _setupPeerConnectionHandlers() {
    if (_peerConnection == null) return;

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      if (_isDisconnecting) return;

      final stateStr = state.toString().split('.').last;
      _updateIceState(stateStr);
      debugPrint('[WebRTC] ICE: $stateStr');

      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          debugPrint('[WebRTC] *** CONNECTED ***');
          _updateState(StreamState.connected, 'Connected');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          debugPrint('[WebRTC] *** ICE FAILED ***');
          _updateState(StreamState.failed, 'Connection failed');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          if (_connectionState == StreamState.connected) {
            _updateState(StreamState.disconnected, 'Disconnected');
          }
          break;
        case RTCIceConnectionState.RTCIceConnectionStateChecking:
          _updateState(StreamState.connecting, 'Connecting...');
          break;
        default:
          break;
      }
    };

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      if (_broadcasterId == null) return;

      _send({
        'type': 'ice-candidate',
        'to': _broadcasterId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      debugPrint('[WebRTC] Track: ${event.track.kind}');

      if (event.streams.isEmpty) return;

      final stream = event.streams[0];

      if (event.track.kind == 'video') {
        debugPrint('[WebRTC] Setting video stream');
        _remoteStream = stream;
        if (_remoteRenderer != null) {
          _remoteRenderer!.srcObject = stream;
        }
        notifyListeners();
      } else if (event.track.kind == 'audio' && _remoteStream == null) {
        _remoteStream = stream;
        if (_remoteRenderer != null) {
          _remoteRenderer!.srcObject = stream;
        }
        notifyListeners();
      }
    };

    _peerConnection!.onAddStream = (MediaStream stream) {
      debugPrint('[WebRTC] onAddStream: ${stream.getTracks().length} tracks');
      if (_remoteStream == null && _remoteRenderer != null) {
        _remoteStream = stream;
        _remoteRenderer!.srcObject = stream;
        notifyListeners();
      }
    };
  }

  Future<void> _processQueuedIceCandidates() async {
    if (_pendingIceCandidates.isEmpty) return;

    debugPrint('[WebRTC] Processing ${_pendingIceCandidates.length} queued candidates');

    for (final data in List.from(_pendingIceCandidates)) {
      await _addIceCandidate(data);
    }
    _pendingIceCandidates.clear();
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    if (!_remoteDescriptionSet || _peerConnection == null) {
      _pendingIceCandidates.add(data);
      return;
    }
    await _addIceCandidate(data);
  }

  Future<void> _addIceCandidate(Map<String, dynamic> data) async {
    if (_peerConnection == null || _isDisconnecting) return;

    try {
      String? candidateStr;
      String? sdpMid;
      int? sdpMLineIndex;

      final candidateData = data['candidate'];

      if (candidateData is String) {
        candidateStr = candidateData;
        sdpMid = data['sdpMid'] as String?;
        sdpMLineIndex = data['sdpMLineIndex'] as int?;
      } else if (candidateData is Map) {
        candidateStr = candidateData['candidate'] as String?;
        sdpMid = candidateData['sdpMid'] as String?;
        sdpMLineIndex = candidateData['sdpMLineIndex'] as int?;
      }

      if (candidateStr == null || candidateStr.isEmpty) return;

      sdpMid ??= sdpMLineIndex?.toString() ?? '0';
      sdpMLineIndex ??= 0;

      final candidate = RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex);
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      debugPrint('[WebRTC] Error adding ICE candidate: $e');
    }
  }

  void toggleAudio() {
    _audioEnabled = !_audioEnabled;
    _applyMediaState();
    notifyListeners();
  }

  void toggleVideo() {
    _videoEnabled = !_videoEnabled;
    _applyMediaState();
    notifyListeners();
  }

  void _applyMediaState() {
    final stream = _remoteRenderer?.srcObject;
    if (stream == null) return;

    for (final track in stream.getAudioTracks()) {
      track.enabled = _audioEnabled;
    }
    for (final track in stream.getVideoTracks()) {
      track.enabled = _videoEnabled;
    }
  }

  /// Disconnect from stream
  Future<void> disconnect() async {
    if (_isDisconnecting) return;

    debugPrint('[WebRTC] Disconnecting...');
    _isDisconnecting = true;
    _updateState(StreamState.disconnected, 'Disconnected');

    await _cleanupInternal();
    _isDisconnecting = false;
  }

  /// Refresh connection - disconnect and reconnect
  Future<bool> refresh() async {
    if (_currentUrl == null) return false;

    debugPrint('[WebRTC] Refreshing connection...');

    final url = _currentUrl!;
    final streamId = _currentStreamId ?? 'pi-camera-stream';

    await disconnect();
    await Future.delayed(const Duration(milliseconds: 300));

    return connect(url, streamId: streamId);
  }

  /// Internal cleanup - closes all resources
  Future<void> _cleanupInternal() async {
    debugPrint('[WebRTC] Cleaning up...');

    // Cancel WebSocket subscription
    await _channelSubscription?.cancel();
    _channelSubscription = null;

    // Close WebSocket
    try {
      await _channel?.sink.close();
    } catch (e) {
      debugPrint('[WebRTC] Error closing channel: $e');
    }
    _channel = null;

    // Clear renderer
    if (_remoteRenderer != null) {
      _remoteRenderer!.srcObject = null;
    }
    _remoteStream = null;

    // Close peer connection
    try {
      await _peerConnection?.close();
    } catch (e) {
      debugPrint('[WebRTC] Error closing peer connection: $e');
    }
    _peerConnection = null;

    // Reset state
    _viewerId = null;
    _broadcasterId = null;
    _remoteDescriptionSet = false;
    _pendingIceCandidates.clear();

    debugPrint('[WebRTC] Cleanup complete');
  }

  @override
  void dispose() {
    _isDisconnecting = true;
    _cleanupInternal();
    _remoteRenderer?.dispose();
    super.dispose();
  }
}
