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

  // Connection state flags for UI to check
  bool get isConnecting => _isConnecting;
  bool get isDisconnecting => _isDisconnecting;
  bool get isOperationInProgress => _isConnecting || _isDisconnecting;

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
    if (_isDisconnecting) {
      debugPrint('[WebRTC] Ignoring offer - disconnecting');
      return;
    }

    debugPrint('[WebRTC] Handling offer from server');
    _broadcasterId = data['from'] as String? ?? _broadcasterId;
    debugPrint('[WebRTC] Broadcaster ID: $_broadcasterId');
    _updateState(StreamState.connecting, 'Setting up connection...');

    try {
      // Close existing peer connection if any
      if (_peerConnection != null) {
        debugPrint('[WebRTC] Closing existing peer connection');
        await _peerConnection!.close();
        _peerConnection = null;
      }

      final iceServers = _iceServers ?? [{'urls': 'stun:stun.l.google.com:19302'}];
      debugPrint('[WebRTC] Using ${iceServers.length} ICE servers');

      final config = <String, dynamic>{
        'iceServers': iceServers,
        'sdpSemantics': 'unified-plan',
        'iceTransportPolicy': 'all',
      };

      debugPrint('[WebRTC] Creating peer connection with config: $config');
      _peerConnection = await createPeerConnection(config);
      debugPrint('[WebRTC] Peer connection created');

      // Set up handlers BEFORE setting remote description
      _setupPeerConnectionHandlers();

      // Add receive-only transceivers for audio and video
      // This ensures we're ready to receive media
      debugPrint('[WebRTC] Adding receive-only transceivers');
      await _peerConnection!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      await _peerConnection!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      debugPrint('[WebRTC] Transceivers added');

      // Set remote description (offer)
      debugPrint('[WebRTC] Setting remote description (offer)');
      final offer = RTCSessionDescription(data['sdp'] as String, 'offer');
      await _peerConnection!.setRemoteDescription(offer);
      _remoteDescriptionSet = true;
      debugPrint('[WebRTC] Remote description set successfully');

      // Process any queued ICE candidates
      await _processQueuedIceCandidates();

      // Create and set local description (answer)
      debugPrint('[WebRTC] Creating answer');
      final answer = await _peerConnection!.createAnswer();
      debugPrint('[WebRTC] Setting local description (answer)');
      await _peerConnection!.setLocalDescription(answer);
      debugPrint('[WebRTC] Local description set');

      // Send answer to server
      debugPrint('[WebRTC] Sending answer to broadcaster');
      _send({
        'type': 'answer',
        'to': _broadcasterId,
        'sdp': answer.sdp,
      });

      _updateState(StreamState.connecting, 'Establishing connection...');
      debugPrint('[WebRTC] Offer handling complete, waiting for ICE connection...');

    } catch (e, stackTrace) {
      debugPrint('[WebRTC] Failed to handle offer: $e');
      debugPrint('[WebRTC] Stack trace: $stackTrace');
      _updateState(StreamState.failed, 'Setup failed: $e');
    }
  }

  void _setupPeerConnectionHandlers() {
    if (_peerConnection == null) return;

    debugPrint('[WebRTC] Setting up peer connection handlers...');

    // ICE Connection State - tracks actual ICE connectivity
    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('[WebRTC] >>> ICE Connection State: $state');
      if (_isDisconnecting) return;

      final stateStr = state.toString().split('.').last;
      _updateIceState(stateStr);

      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          debugPrint('[WebRTC] *** ICE CONNECTED ***');
          _updateState(StreamState.connected, 'Connected');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          debugPrint('[WebRTC] *** ICE FAILED ***');
          _updateState(StreamState.failed, 'Connection failed');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          debugPrint('[WebRTC] *** ICE DISCONNECTED ***');
          if (_connectionState == StreamState.connected) {
            _updateState(StreamState.disconnected, 'Disconnected');
          }
          break;
        case RTCIceConnectionState.RTCIceConnectionStateChecking:
          debugPrint('[WebRTC] *** ICE CHECKING ***');
          _updateState(StreamState.connecting, 'Connecting...');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateNew:
          debugPrint('[WebRTC] *** ICE NEW ***');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          debugPrint('[WebRTC] *** ICE CLOSED ***');
          break;
        default:
          debugPrint('[WebRTC] ICE state: $stateStr');
          break;
      }
    };

    // Peer Connection State - overall connection health
    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[WebRTC] >>> Peer Connection State: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _updateState(StreamState.failed, 'Peer connection failed');
      }
    };

    // ICE Gathering State - local candidate gathering progress
    _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
      debugPrint('[WebRTC] >>> ICE Gathering State: $state');
    };

    // Signaling State
    _peerConnection!.onSignalingState = (RTCSignalingState state) {
      debugPrint('[WebRTC] >>> Signaling State: $state');
    };

    // ICE Candidate - our local candidates to send to remote
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) {
        debugPrint('[WebRTC] ICE gathering complete (null candidate)');
        return;
      }
      if (_broadcasterId == null) {
        debugPrint('[WebRTC] No broadcaster ID, cannot send ICE candidate');
        return;
      }

      debugPrint('[WebRTC] Sending local ICE: ${candidate.candidate!.substring(0, 50.clamp(0, candidate.candidate!.length))}...');
      _send({
        'type': 'ice-candidate',
        'to': _broadcasterId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    // Track event - remote media tracks
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      debugPrint('[WebRTC] >>> onTrack: ${event.track.kind}, streams: ${event.streams.length}');

      if (event.streams.isEmpty) {
        debugPrint('[WebRTC] Warning: Track has no streams');
        return;
      }

      final stream = event.streams[0];
      debugPrint('[WebRTC] Stream ID: ${stream.id}, tracks: ${stream.getTracks().length}');

      if (event.track.kind == 'video') {
        debugPrint('[WebRTC] Setting video stream to renderer');
        _remoteStream = stream;
        if (_remoteRenderer != null) {
          _remoteRenderer!.srcObject = stream;
        }
        notifyListeners();
      } else if (event.track.kind == 'audio') {
        debugPrint('[WebRTC] Audio track received');
        if (_remoteStream == null && _remoteRenderer != null) {
          _remoteStream = stream;
          _remoteRenderer!.srcObject = stream;
          notifyListeners();
        }
      }
    };

    // Legacy addStream event
    _peerConnection!.onAddStream = (MediaStream stream) {
      debugPrint('[WebRTC] >>> onAddStream: ${stream.getTracks().length} tracks');
      if (_remoteStream == null && _remoteRenderer != null) {
        _remoteStream = stream;
        _remoteRenderer!.srcObject = stream;
        notifyListeners();
      }
    };

    debugPrint('[WebRTC] Peer connection handlers set up');
  }

  Future<void> _processQueuedIceCandidates() async {
    if (_pendingIceCandidates.isEmpty) {
      debugPrint('[WebRTC] No queued ICE candidates to process');
      return;
    }

    debugPrint('[WebRTC] Processing ${_pendingIceCandidates.length} queued remote ICE candidates');

    int added = 0;
    for (final data in List.from(_pendingIceCandidates)) {
      final success = await _addIceCandidate(data);
      if (success) added++;
    }
    _pendingIceCandidates.clear();
    debugPrint('[WebRTC] Processed queued candidates, $added added successfully');
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    if (!_remoteDescriptionSet || _peerConnection == null) {
      debugPrint('[WebRTC] Queueing ICE candidate (remote desc set: $_remoteDescriptionSet, pc: ${_peerConnection != null})');
      _pendingIceCandidates.add(data);
      return;
    }
    await _addIceCandidate(data);
  }

  Future<bool> _addIceCandidate(Map<String, dynamic> data) async {
    if (_peerConnection == null || _isDisconnecting) {
      debugPrint('[WebRTC] Cannot add ICE: pc=${_peerConnection != null}, disconnecting=$_isDisconnecting');
      return false;
    }

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

      if (candidateStr == null || candidateStr.isEmpty) {
        debugPrint('[WebRTC] Empty ICE candidate string');
        return false;
      }

      // Provide defaults if missing
      sdpMid ??= sdpMLineIndex?.toString() ?? '0';
      sdpMLineIndex ??= 0;

      debugPrint('[WebRTC] Adding remote ICE candidate: ${candidateStr.substring(0, 50.clamp(0, candidateStr.length))}...');

      final candidate = RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex);
      await _peerConnection!.addCandidate(candidate);
      debugPrint('[WebRTC] Remote ICE candidate added successfully');
      return true;
    } catch (e) {
      debugPrint('[WebRTC] Error adding ICE candidate: $e');
      return false;
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
    if (_isDisconnecting) {
      debugPrint('[WebRTC] Already disconnecting, ignoring');
      return;
    }

    debugPrint('[WebRTC] Disconnecting...');
    _isDisconnecting = true;

    // Update state first
    _updateState(StreamState.disconnected, 'Disconnected');

    // Perform cleanup
    await _cleanupInternal();

    // Reset all flags
    _isDisconnecting = false;
    _isConnecting = false; // Reset in case it was stuck
    debugPrint('[WebRTC] Disconnect complete');
  }

  /// Refresh connection - disconnect and reconnect smoothly
  Future<bool> refresh() async {
    // Guard against refresh while other operations are in progress
    if (_isConnecting || _isDisconnecting) {
      debugPrint('[WebRTC] Operation in progress, ignoring refresh');
      return false;
    }

    if (_currentUrl == null) {
      debugPrint('[WebRTC] No URL to refresh, ignoring');
      return false;
    }

    debugPrint('[WebRTC] Refreshing connection...');

    // Save current settings before disconnect clears them
    final url = _currentUrl!;
    final streamId = _currentStreamId ?? 'pi-camera-stream';

    // Disconnect first
    await disconnect();

    // Small delay to ensure cleanup is complete
    await Future.delayed(const Duration(milliseconds: 200));

    // Reconnect
    final result = await connect(url, streamId: streamId);
    debugPrint('[WebRTC] Refresh complete, connected: $result');

    return result;
  }

  /// Internal cleanup - closes all resources thoroughly
  Future<void> _cleanupInternal() async {
    debugPrint('[WebRTC] Cleaning up...');

    // Cancel WebSocket subscription first
    await _channelSubscription?.cancel();
    _channelSubscription = null;

    // Close WebSocket
    try {
      await _channel?.sink.close();
    } catch (e) {
      debugPrint('[WebRTC] Error closing channel: $e');
    }
    _channel = null;

    // Stop all tracks explicitly before clearing renderer
    // This ensures proper resource release
    if (_remoteStream != null) {
      debugPrint('[WebRTC] Stopping ${_remoteStream!.getTracks().length} tracks');
      for (final track in _remoteStream!.getTracks()) {
        try {
          track.stop();
        } catch (e) {
          debugPrint('[WebRTC] Error stopping track: $e');
        }
      }
    }

    // Clear renderer
    if (_remoteRenderer != null) {
      _remoteRenderer!.srcObject = null;
    }
    _remoteStream = null;

    // Remove peer connection event handlers before closing
    // This prevents callbacks firing on destroyed objects
    if (_peerConnection != null) {
      _peerConnection!.onIceConnectionState = null;
      _peerConnection!.onIceCandidate = null;
      _peerConnection!.onTrack = null;
      _peerConnection!.onAddStream = null;
      _peerConnection!.onConnectionState = null;
      _peerConnection!.onIceGatheringState = null;
    }

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

    // Small delay to ensure resources are fully released
    await Future.delayed(const Duration(milliseconds: 100));

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
