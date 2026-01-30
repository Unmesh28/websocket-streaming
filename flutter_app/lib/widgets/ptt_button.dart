import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Push-to-Talk button widget
/// Toggle mode: Press once to start talking, press again to stop
class PTTButton extends StatelessWidget {
  final bool enabled;
  final bool isTalking;
  final VoidCallback onTalkStart;
  final VoidCallback onTalkEnd;
  final VoidCallback? onRequestMic;

  const PTTButton({
    super.key,
    required this.enabled,
    required this.isTalking,
    required this.onTalkStart,
    required this.onTalkEnd,
    this.onRequestMic,
  });

  void _onPressed() {
    debugPrint('[PTT] Button pressed, enabled: $enabled, isTalking: $isTalking');

    if (!enabled) {
      // If mic not enabled, try to request permission
      onRequestMic?.call();
      return;
    }

    HapticFeedback.mediumImpact();

    if (isTalking) {
      debugPrint('[PTT] Stopping talk');
      onTalkEnd();
    } else {
      debugPrint('[PTT] Starting talk');
      onTalkStart();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 90,
        height: 90,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: enabled
                ? (isTalking
                    ? [Colors.red.shade400, Colors.red.shade700]
                    : [Colors.blue.shade400, Colors.blue.shade700])
                : [Colors.grey.shade500, Colors.grey.shade700],
          ),
          border: Border.all(
            color: Colors.white.withOpacity(0.3),
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: isTalking
                  ? Colors.red.withOpacity(0.5)
                  : Colors.black.withOpacity(0.3),
              blurRadius: isTalking ? 15 : 10,
              spreadRadius: isTalking ? 2 : 0,
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              enabled
                  ? (isTalking ? Icons.mic : Icons.mic_none)
                  : Icons.mic_off,
              color: Colors.white,
              size: 32,
            ),
            const SizedBox(height: 2),
            Text(
              enabled
                  ? (isTalking ? 'STOP' : 'TALK')
                  : 'NO MIC',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
