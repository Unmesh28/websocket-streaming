import 'package:flutter/material.dart';
import '../services/webrtc_service.dart';

class ConnectionStatus extends StatelessWidget {
  final StreamConnectionState state;
  final String message;
  final String iceState;

  const ConnectionStatus({
    super.key,
    required this.state,
    required this.message,
    required this.iceState,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStatusIndicator(),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (iceState.isNotEmpty)
                Text(
                  'ICE: $iceState',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIndicator() {
    Color color;
    IconData icon;

    switch (state) {
      case StreamConnectionState.connected:
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case StreamConnectionState.connecting:
        color = Colors.orange;
        icon = Icons.sync;
        break;
      case StreamConnectionState.failed:
        color = Colors.red;
        icon = Icons.error;
        break;
      case StreamConnectionState.disconnected:
      default:
        color = Colors.grey;
        icon = Icons.circle_outlined;
    }

    if (state == StreamConnectionState.connecting) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );
    }

    return Icon(
      icon,
      color: color,
      size: 16,
    );
  }
}
