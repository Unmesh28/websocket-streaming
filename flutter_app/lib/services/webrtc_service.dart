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

      // Join stream (not register!)
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
        _iceServers = List<Map<String, dynamic>>.from(data['iceServers']);
        debugPrint('[WebRTC] Got ${_iceServers!.length} ICE servers');
      }
    } catch (e) {
      debugPrint('[WebRTC] Failed to fetch TURN credentials: $e');
      _iceServers = [
        {'urls': 'stun:stun.l.google.com:19302'}
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
      // Create peer connection
      final config = {
        'iceServers': _iceServers ?? [{'urls': 'stun:stun.l.google.com:19302'}],
        'sdpSemantics': 'unified-plan',
      };

      _peerConnection = await createPeerConnection(config);

      // Set up event handlers
      _peerConnection!.onIceConnectionState = (state) {
        final stateStr = state.toString().split('.').last;
        _updateIceState(stateStr);
        debugPrint('[WebRTC] ====== ICE CONNECTION STATE: $stateStr ======');

        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          debugPrint('[WebRTC] *** SUCCESS: CONNECTION ESTABLISHED ***');
          _updateState(StreamState.connected, 'Connected');
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          debugPrint('[WebRTC] *** FAILED: ICE CONNECTION FAILED ***');
          _updateState(StreamState.failed, 'ICE connection failed');
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
          debugPrint('[WebRTC] *** DISCONNECTED ***');
          _updateState(StreamState.disconnected, 'Disconnected');
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
          debugPrint('[WebRTC] Checking ICE connectivity...');
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateNew) {
          debugPrint('[WebRTC] ICE state is new, waiting for candidates...');
        }
      };

      _peerConnection!.onIceCandidate = (candidate) {
        debugPrint('[WebRTC] Local ICE candidate generated: ${candidate.candidate?.substring(0, 50) ?? "null"}...');
        if (candidate.candidate != null && _broadcasterId != null) {
          debugPrint('[WebRTC] Sending ICE candidate to $_broadcasterId');
          _send({
            'type': 'ice-candidate',
            'to': _broadcasterId,
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          });
        }
      };

      _peerConnection!.onIceGatheringState = (state) {
        debugPrint('[WebRTC] ICE gathering state: $state');
      };

      _peerConnection!.onConnectionState = (state) {
        debugPrint('[WebRTC] Peer connection state: $state');
      };

      _peerConnection!.onTrack = (event) {
        debugPrint('[WebRTC] Got remote track: ${event.track.kind}, enabled: ${event.track.enabled}');
        debugPrint('[WebRTC] Track ID: ${event.track.id}, streams: ${event.streams.length}');
        if (event.streams.isNotEmpty) {
          debugPrint('[WebRTC] Setting remote stream with ${event.streams[0].getTracks().length} tracks');
          _remoteRenderer.srcObject = event.streams[0];
          notifyListeners();
        } else {
          debugPrint('[WebRTC] WARNING: No streams in track event!');
        }
      };

      // Set remote description (offer)
      final offer = RTCSessionDescription(
        data['sdp'] as String,
        'offer',
      );
      await _peerConnection!.setRemoteDescription(offer);

      // Create and send answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      _send({
        'type': 'answer',
        'to': _broadcasterId,
        'sdp': answer.sdp,
      });

      _updateState(StreamState.connecting, 'Answer sent, establishing connection...');

    } catch (e) {
      debugPrint('[WebRTC] Failed to handle offer: $e');
      _updateState(StreamState.failed, 'Failed to handle offer: $e');
    }
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    if (_peerConnection == null) return;

    try {
      // Debug: print full ICE candidate data received
      debugPrint('[WebRTC] ICE candidate data: $data');

      // Handle different ICE candidate formats from server
      String? candidateStr;
      String? sdpMid;
      int? sdpMLineIndex;

      final candidateData = data['candidate'];
      debugPrint('[WebRTC] candidateData type: ${candidateData.runtimeType}, value: $candidateData');

      if (candidateData is String) {
        // Direct string format
        candidateStr = candidateData;
        sdpMid = data['sdpMid'] as String?;
        sdpMLineIndex = data['sdpMLineIndex'] as int?;
      } else if (candidateData is Map) {
        // Object format: {candidate: "...", sdpMid: "...", sdpMLineIndex: 0}
        candidateStr = candidateData['candidate'] as String?;
        sdpMid = candidateData['sdpMid'] as String?;
        sdpMLineIndex = candidateData['sdpMLineIndex'] as int?;
      }

      debugPrint('[WebRTC] Parsed: candidateStr=$candidateStr, sdpMid=$sdpMid, sdpMLineIndex=$sdpMLineIndex');

      // Skip if no valid candidate string
      if (candidateStr == null || candidateStr.isEmpty) {
        debugPrint('[WebRTC] Skipping empty ICE candidate');
        return;
      }

      // Ensure sdpMid has a value - native layer may crash if null
      // Default to "0" or "audio"/"video" based on sdpMLineIndex
      if (sdpMid == null || sdpMid.isEmpty) {
        sdpMid = sdpMLineIndex?.toString() ?? '0';
        debugPrint('[WebRTC] Using default sdpMid: $sdpMid');
      }

      final candidate = RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex ?? 0);
      await _peerConnection!.addCandidate(candidate);
      debugPrint('[WebRTC] Added ICE candidate successfully');
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

      await _peerConnection?.close();
      _peerConnection = null;

      _viewerId = null;
      _broadcasterId = null;
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
