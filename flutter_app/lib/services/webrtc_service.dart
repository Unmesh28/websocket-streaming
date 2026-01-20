import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;

enum StreamStreamConnectionState {
  disconnected,
  connecting,
  connected,
  failed,
}

class WebRTCService extends ChangeNotifier {
  WebSocketChannel? _channel;
  RTCPeerConnection? _peerConnection;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  StreamConnectionState _connectionState = StreamConnectionState.disconnected;
  String _statusMessage = 'Disconnected';
  String _iceState = '';

  bool _audioEnabled = true;
  bool _videoEnabled = true;

  String? _currentUrl;
  List<Map<String, dynamic>>? _iceServers;

  // Getters
  StreamConnectionState get connectionState => _connectionState;
  String get statusMessage => _statusMessage;
  String get iceState => _iceState;
  bool get audioEnabled => _audioEnabled;
  bool get videoEnabled => _videoEnabled;
  RTCVideoRenderer get remoteRenderer => _remoteRenderer;
  bool get isConnected => _connectionState == StreamConnectionState.connected;

  WebRTCService() {
    _initRenderer();
  }

  Future<void> _initRenderer() async {
    await _remoteRenderer.initialize();
  }

  void _updateState(StreamConnectionState state, String message) {
    _connectionState = state;
    _statusMessage = message;
    notifyListeners();
  }

  void _updateIceState(String state) {
    _iceState = state;
    notifyListeners();
  }

  Future<void> connect(String serverUrl) async {
    if (_connectionState == StreamConnectionState.connecting) return;

    _currentUrl = serverUrl;
    _updateState(StreamConnectionState.connecting, 'Connecting...');

    try {
      // Fetch TURN credentials first
      await _fetchTurnCredentials(serverUrl);

      // Connect WebSocket
      final wsUrl = _getWebSocketUrl(serverUrl);
      _updateState(StreamConnectionState.connecting, 'Connecting to $wsUrl...');

      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          _updateState(StreamConnectionState.failed, 'WebSocket error: $error');
        },
        onDone: () {
          if (_connectionState != StreamConnectionState.disconnected) {
            _updateState(StreamConnectionState.disconnected, 'Connection closed');
          }
        },
      );

      // Register as viewer
      _send({'type': 'register', 'role': 'viewer'});
      _updateState(StreamConnectionState.connecting, 'Registered, waiting for stream...');

    } catch (e) {
      _updateState(StreamConnectionState.failed, 'Connection failed: $e');
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
        debugPrint('Got ${_iceServers!.length} ICE servers');
      }
    } catch (e) {
      debugPrint('Failed to fetch TURN credentials: $e');
      // Use default STUN server
      _iceServers = [
        {'urls': 'stun:stun.l.google.com:19302'}
      ];
    }
  }

  String _getWebSocketUrl(String url) {
    // Handle various URL formats
    url = url.trim();

    if (url.startsWith('https://')) {
      return url.replaceFirst('https://', 'wss://');
    } else if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'ws://');
    } else if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      // Assume https if no protocol
      return 'wss://$url';
    }
    return url;
  }

  void _send(Map<String, dynamic> message) {
    if (_channel != null) {
      _channel!.sink.add(json.encode(message));
    }
  }

  void _onMessage(dynamic message) {
    try {
      final data = json.decode(message as String);
      final type = data['type'] as String?;

      switch (type) {
        case 'offer':
          _handleOffer(data);
          break;
        case 'ice-candidate':
          _handleIceCandidate(data);
          break;
        case 'streamer-disconnected':
          _updateState(StreamConnectionState.disconnected, 'Streamer disconnected');
          break;
        default:
          debugPrint('Unknown message type: $type');
      }
    } catch (e) {
      debugPrint('Error parsing message: $e');
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    _updateState(StreamConnectionState.connecting, 'Received offer, creating answer...');

    try {
      // Create peer connection
      final config = {
        'iceServers': _iceServers ?? [{'urls': 'stun:stun.l.google.com:19302'}],
        'sdpSemantics': 'unified-plan',
      };

      _peerConnection = await createPeerConnection(config);

      // Set up event handlers
      _peerConnection!.onIceStreamConnectionState = (state) {
        final stateStr = state.toString().split('.').last;
        _updateIceState(stateStr);
        debugPrint('ICE state: $stateStr');

        if (state == RTCIceStreamConnectionState.RTCIceStreamConnectionStateConnected ||
            state == RTCIceStreamConnectionState.RTCIceStreamConnectionStateCompleted) {
          _updateState(StreamConnectionState.connected, 'Connected');
        } else if (state == RTCIceStreamConnectionState.RTCIceStreamConnectionStateFailed) {
          _updateState(StreamConnectionState.failed, 'ICE connection failed');
        } else if (state == RTCIceStreamConnectionState.RTCIceStreamConnectionStateDisconnected) {
          _updateState(StreamConnectionState.disconnected, 'Disconnected');
        }
      };

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null) {
          _send({
            'type': 'ice-candidate',
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          });
        }
      };

      _peerConnection!.onTrack = (event) {
        debugPrint('Got remote track: ${event.track.kind}');
        if (event.streams.isNotEmpty) {
          _remoteRenderer.srcObject = event.streams[0];
          notifyListeners();
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
        'sdp': answer.sdp,
      });

      _updateState(StreamConnectionState.connecting, 'Answer sent, establishing connection...');

    } catch (e) {
      _updateState(StreamConnectionState.failed, 'Failed to handle offer: $e');
    }
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    if (_peerConnection == null) return;

    try {
      final candidateData = data['candidate'] as Map<String, dynamic>;
      final candidate = RTCIceCandidate(
        candidateData['candidate'] as String,
        candidateData['sdpMid'] as String?,
        candidateData['sdpMLineIndex'] as int?,
      );
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      debugPrint('Error adding ICE candidate: $e');
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

    // Toggle audio tracks
    for (final track in stream.getAudioTracks()) {
      track.enabled = _audioEnabled;
    }

    // Toggle video tracks
    for (final track in stream.getVideoTracks()) {
      track.enabled = _videoEnabled;
    }
  }

  Future<void> disconnect() async {
    _updateState(StreamConnectionState.disconnected, 'Disconnected');

    await _cleanup();
  }

  Future<void> refresh() async {
    if (_currentUrl == null) return;

    await _cleanup();
    await Future.delayed(const Duration(milliseconds: 500));
    await connect(_currentUrl!);
  }

  Future<void> _cleanup() async {
    try {
      _channel?.sink.close();
      _channel = null;

      _remoteRenderer.srcObject = null;

      await _peerConnection?.close();
      _peerConnection = null;
    } catch (e) {
      debugPrint('Cleanup error: $e');
    }
  }

  @override
  void dispose() {
    _cleanup();
    _remoteRenderer.dispose();
    super.dispose();
  }
}
