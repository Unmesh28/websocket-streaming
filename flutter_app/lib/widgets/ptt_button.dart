import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Push-to-Talk button widget
/// Press and hold to talk, release to stop
class PTTButton extends StatefulWidget {
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

  @override
  State<PTTButton> createState() => _PTTButtonState();
}

class _PTTButtonState extends State<PTTButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    if (!widget.enabled) {
      // If mic not enabled, try to request permission
      widget.onRequestMic?.call();
      return;
    }

    setState(() => _isPressed = true);
    _animationController.forward();

    // Haptic feedback
    HapticFeedback.mediumImpact();

    widget.onTalkStart();
  }

  void _handleTapUp(TapUpDetails details) {
    _release();
  }

  void _handleTapCancel() {
    _release();
  }

  void _release() {
    if (!_isPressed) return;

    setState(() => _isPressed = false);
    _animationController.reverse();

    if (widget.enabled) {
      widget.onTalkEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isActive = widget.isTalking || _isPressed;

    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: widget.enabled
                      ? (isActive
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
                    color: isActive
                        ? Colors.red.withOpacity(0.5)
                        : Colors.black.withOpacity(0.3),
                    blurRadius: isActive ? 15 : 10,
                    spreadRadius: isActive ? 2 : 0,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.enabled
                        ? (isActive ? Icons.mic : Icons.mic_none)
                        : Icons.mic_off,
                    color: Colors.white,
                    size: 32,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.enabled
                        ? (isActive ? 'TALKING' : 'TALK')
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
        },
      ),
    );
  }
}
