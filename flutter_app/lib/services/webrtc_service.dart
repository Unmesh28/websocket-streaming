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
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  MediaStream? _remoteStream;

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

  // Queue for ICE candidates that arrive before remote description is set
  final List<Map<String, dynamic>> _pendingIceCandidates = [];
  bool _remoteDescriptionSet = false;

  // Getters
  StreamState get connectionState => _connectionState;
  String get statusMessage => _statusMessage;
  String get iceState => _iceState;
  bool get audioEnabled => _audioEnabled;
  bool get videoEnabled => _videoEnabled;
  RTCVideoRenderer get remoteRenderer => _remoteRenderer;
  bool get isConnected => _connectionState == StreamState.connected;

  WebRTCService() {
    _initRenderer();
  }

  Future<void> _initRenderer() async {
    await _remoteRenderer.initialize();
  }

  void _updateState(StreamState state, String message) {
    _connectionState = state;
    _statusMessage = message;
    debugPrint('[WebRTC] State: $state - $message');
    notifyListeners();
  }

  void _updateIceState(String state) {
    _iceState = state;
    notifyListeners();
  }

  Future<void> connect(String serverUrl, {String streamId = 'pi-camera-stream'}) async {
    if (_connectionState == StreamState.connecting) return;

    _currentUrl = serverUrl;
    _currentStreamId = streamId;
    _remoteDescriptionSet = false;
    _pendingIceCandidates.clear();
    _updateState(StreamState.connecting, 'Connecting...');

    try {
      // Fetch TURN credentials first
      await _fetchTurnCredentials(serverUrl);

      // Connect WebSocket
      final wsUrl = _getWebSocketUrl(serverUrl);
      _updateState(StreamState.connecting, 'Connecting to $wsUrl...');
      debugPrint('[WebRTC] Connecting to WebSocket: $wsUrl');

      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          debugPrint('[WebRTC] WebSocket error: $error');
          _updateState(StreamState.failed, 'WebSocket error: $error');
        },
        onDone: () {
          debugPrint('[WebRTC] WebSocket closed');
          if (_connectionState != StreamState.disconnected) {
            _updateState(StreamState.disconnected, 'Connection closed');
          }
        },
      );

      // Wait a moment for WebSocket to be ready, then join
      await Future.delayed(const Duration(milliseconds: 100));

      // Join stream
      final joinMsg = {'type': 'join', 'stream_id': streamId};
      debugPrint('[WebRTC] Sending join: $joinMsg');
      _send(joinMsg);
      _updateState(StreamState.connecting, 'Joining stream...');

    } catch (e) {
      debugPrint('[WebRTC] Connection failed: $e');
      _updateState(StreamState.failed, 'Connection failed: $e');
    }
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
        debugPrint('[WebRTC] Raw TURN response: $data');

        final rawServers = List<Map<String, dynamic>>.from(data['iceServers']);

        // Normalize ICE servers for flutter_webrtc
        _iceServers = [];
        for (var server in rawServers) {
          final urls = server['urls'];
          final username = server['username'];
          final credential = server['credential'];

          // If urls is an array, create separate entries for each URL
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

        debugPrint('[WebRTC] Got ${_iceServers!.length} ICE servers (normalized)');
        for (var server in _iceServers!) {
          final hasAuth = server.containsKey('username');
          debugPrint('[WebRTC]   - ${server['urls']} (auth: $hasAuth)');
          if (hasAuth) {
            debugPrint('[WebRTC]     username: ${(server['username'] as String).substring(0, 20)}...');
          }
        }
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
    if (_channel != null) {
      final jsonStr = json.encode(message);
      debugPrint('[WebRTC] Sending: ${message['type']}');
      _channel!.sink.add(jsonStr);
    }
  }

  void _onMessage(dynamic message) {
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
        default:
          debugPrint('[WebRTC] Unknown message type: $type');
      }
    } catch (e) {
      debugPrint('[WebRTC] Error parsing message: $e');
    }
  }

  void _handleJoined(Map<String, dynamic> data) {
    _viewerId = data['viewer_id'] as String?;
    _broadcasterId = data['stream_id'] as String?;
    debugPrint('[WebRTC] Joined as $_viewerId, broadcaster: $_broadcasterId');
    _updateState(StreamState.connecting, 'Joined, waiting for offer...');
  }

  void _handleError(Map<String, dynamic> data) {
    final message = data['message'] as String? ?? 'Unknown error';
    debugPrint('[WebRTC] Server error: $message');
    _updateState(StreamState.failed, message);
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    debugPrint('[WebRTC] Received offer from ${data['from']}');
    _broadcasterId = data['from'] as String? ?? _broadcasterId;
    _updateState(StreamState.connecting, 'Received offer, creating answer...');

    try {
      final iceServers = _iceServers ?? [{'urls': 'stun:stun.l.google.com:19302'}];
      debugPrint('[WebRTC] Creating peer connection with ${iceServers.length} ICE servers');

      final config = <String, dynamic>{
        'iceServers': iceServers,
        'sdpSemantics': 'unified-plan',
        // Try 'relay' to force TURN for debugging, 'all' for production
        'iceTransportPolicy': 'all',
      };

      _peerConnection = await createPeerConnection(config);
      debugPrint('[WebRTC] Peer connection created');

      // Set up ALL event handlers FIRST
      _setupPeerConnectionHandlers();

      // Set remote description (offer) - this enables ICE candidate processing
      final offer = RTCSessionDescription(
        data['sdp'] as String,
        'offer',
      );
      await _peerConnection!.setRemoteDescription(offer);
      _remoteDescriptionSet = true;
      debugPrint('[WebRTC] Remote description set');

      // Process any queued ICE candidates
      await _processQueuedIceCandidates();

      // Create and send answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      debugPrint('[WebRTC] Local description set');

      _send({
        'type': 'answer',
        'to': _broadcasterId,
        'sdp': answer.sdp,
      });

      _updateState(StreamState.connecting, 'Answer sent, establishing connection...');

    } catch (e, stackTrace) {
      debugPrint('[WebRTC] Failed to handle offer: $e');
      debugPrint('[WebRTC] Stack trace: $stackTrace');
      _updateState(StreamState.failed, 'Failed to handle offer: $e');
    }
  }

  void _setupPeerConnectionHandlers() {
    if (_peerConnection == null) return;

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      final stateStr = state.toString().split('.').last;
      _updateIceState(stateStr);
      debugPrint('[WebRTC] ############################################');
      debugPrint('[WebRTC] ICE CONNECTION STATE: $stateStr');
      debugPrint('[WebRTC] ############################################');

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        debugPrint('[WebRTC] *** SUCCESS: MEDIA SHOULD BE FLOWING ***');
        _updateState(StreamState.connected, 'Connected');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        debugPrint('[WebRTC] *** FAILED: ICE CONNECTION FAILED ***');
        _updateState(StreamState.failed, 'ICE connection failed');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        debugPrint('[WebRTC] *** DISCONNECTED ***');
        _updateState(StreamState.disconnected, 'Disconnected');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
        debugPrint('[WebRTC] ICE checking connectivity...');
        _updateState(StreamState.connecting, 'Checking connectivity...');
      }
    };

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) {
        debugPrint('[WebRTC] ICE gathering complete (null candidate)');
        return;
      }

      final candidateStr = candidate.candidate!;
      final isRelay = candidateStr.contains('typ relay');
      debugPrint('[WebRTC] Local ICE: ${candidateStr.substring(0, candidateStr.length.clamp(0, 60))}... relay=$isRelay');

      if (_broadcasterId != null) {
        _send({
          'type': 'ice-candidate',
          'to': _broadcasterId,
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };

    _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
      debugPrint('[WebRTC] ICE gathering state: $state');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        debugPrint('[WebRTC] ICE gathering COMPLETE');
      }
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[WebRTC] Peer connection state: $state');
    };

    _peerConnection!.onSignalingState = (RTCSignalingState state) {
      debugPrint('[WebRTC] Signaling state: $state');
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      debugPrint('[WebRTC] *** GOT TRACK: ${event.track.kind} ***');
      debugPrint('[WebRTC] Track ID: ${event.track.id}, enabled: ${event.track.enabled}');

      if (event.streams.isEmpty) {
        debugPrint('[WebRTC] WARNING: No streams in track event!');
        return;
      }

      final stream = event.streams[0];
      debugPrint('[WebRTC] Stream ID: ${stream.id}, tracks: ${stream.getTracks().length}');

      // Only set srcObject for video tracks to prevent overwrite
      if (event.track.kind == 'video') {
        debugPrint('[WebRTC] Setting VIDEO stream to renderer');
        _remoteStream = stream;
        _remoteRenderer.srcObject = stream;
        notifyListeners();
      } else if (event.track.kind == 'audio' && _remoteStream == null) {
        debugPrint('[WebRTC] Setting AUDIO stream to renderer (no video yet)');
        _remoteStream = stream;
        _remoteRenderer.srcObject = stream;
        notifyListeners();
      } else {
        debugPrint('[WebRTC] Audio track received, video stream already set');
      }
    };

    _peerConnection!.onAddStream = (MediaStream stream) {
      debugPrint('[WebRTC] onAddStream: ${stream.id}, tracks: ${stream.getTracks().length}');
      // This is deprecated but some implementations still use it
      if (_remoteStream == null) {
        _remoteStream = stream;
        _remoteRenderer.srcObject = stream;
        notifyListeners();
      }
    };
  }

  Future<void> _processQueuedIceCandidates() async {
    if (_pendingIceCandidates.isEmpty) return;

    debugPrint('[WebRTC] Processing ${_pendingIceCandidates.length} queued ICE candidates');

    for (final data in _pendingIceCandidates) {
      await _addIceCandidate(data);
    }

    _pendingIceCandidates.clear();
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    // If remote description not set yet, queue the candidate
    if (!_remoteDescriptionSet || _peerConnection == null) {
      debugPrint('[WebRTC] Queueing ICE candidate (remote description not set yet)');
      _pendingIceCandidates.add(data);
      return;
    }

    await _addIceCandidate(data);
  }

  Future<void> _addIceCandidate(Map<String, dynamic> data) async {
    if (_peerConnection == null) return;

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
        debugPrint('[WebRTC] Skipping empty ICE candidate');
        return;
      }

      // Ensure sdpMid has a value
      sdpMid ??= sdpMLineIndex?.toString() ?? '0';
      sdpMLineIndex ??= 0;

      final isRelay = candidateStr.contains('typ relay');
      debugPrint('[WebRTC] Adding remote ICE: ${candidateStr.substring(0, candidateStr.length.clamp(0, 50))}... relay=$isRelay');

      final candidate = RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex);
      await _peerConnection!.addCandidate(candidate);
      debugPrint('[WebRTC] Remote ICE candidate added successfully');
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
    final stream = _remoteRenderer.srcObject;
    if (stream == null) return;

    for (final track in stream.getAudioTracks()) {
      track.enabled = _audioEnabled;
    }

    for (final track in stream.getVideoTracks()) {
      track.enabled = _videoEnabled;
    }
  }

  Future<void> disconnect() async {
    _updateState(StreamState.disconnected, 'Disconnected');
    await _cleanup();
  }

  Future<void> refresh() async {
    if (_currentUrl == null) return;

    await _cleanup();
    await Future.delayed(const Duration(milliseconds: 500));
    await connect(_currentUrl!, streamId: _currentStreamId ?? 'pi-camera-stream');
  }

  Future<void> _cleanup() async {
    try {
      _channel?.sink.close();
      _channel = null;

      _remoteRenderer.srcObject = null;
      _remoteStream = null;

      await _peerConnection?.close();
      _peerConnection = null;

      _viewerId = null;
      _broadcasterId = null;
      _remoteDescriptionSet = false;
      _pendingIceCandidates.clear();
    } catch (e) {
      debugPrint('[WebRTC] Cleanup error: $e');
    }
  }

  @override
  void dispose() {
    _cleanup();
    _remoteRenderer.dispose();
    super.dispose();
  }
}
