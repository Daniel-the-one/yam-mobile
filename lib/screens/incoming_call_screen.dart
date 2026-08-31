import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';

/// Overlay PLEIN ÉCRAN d'appel entrant : dégradé sombre façon Meet,
/// avatar entouré de 3 anneaux bleus pulsants, refuser / accepter.
class IncomingCallScreen extends StatelessWidget {
  const IncomingCallScreen({
    super.key,
    required this.app,
    required this.onAccept,
    required this.onRefuse,
  });

  final AppState app;
  final VoidCallback onAccept;
  final VoidCallback onRefuse;

  @override
  Widget build(BuildContext context) {
    final name = app.call.remoteName ?? 'Inconnu';
    final devId = app.call.remoteId ?? '';
    final initial = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    final isVideo = app.call.videoEnabled;

    return Container(
      decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.75),
            radius: 1.2,
            colors: [YamColors.callCardTop, YamColors.callCardBottom],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'APPEL ENTRANT',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 28),
              _PulsingAvatar(initial: initial),
              const SizedBox(height: 24),
              Text(name,
                  style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      color: Colors.white)),
              const SizedBox(height: 6),
              Text(devId, style: mono(size: 13, color: Colors.white38)),
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color.fromRGBO(255, 255, 255, 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isVideo
                          ? Icons.videocam_rounded
                          : Icons.call_rounded,
                      size: 14,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isVideo ? 'Appel vidéo' : 'Appel audio',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RoundAction(
                    icon: Icons.call_end_rounded,
                    color: YamColors.danger,
                    label: 'Refuser',
                    onTap: onRefuse,
                  ),
                  const SizedBox(width: 56),
                  _RoundAction(
                    icon: Icons.call_rounded,
                    color: YamColors.accept,
                    label: 'Accepter',
                    onTap: onAccept,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
  }
}

/// Avatar circulaire entouré de trois anneaux qui pulsent en décalé.
class _PulsingAvatar extends StatefulWidget {
  const _PulsingAvatar({required this.initial});

  final String initial;

  @override
  State<_PulsingAvatar> createState() => _PulsingAvatarState();
}

class _PulsingAvatarState extends State<_PulsingAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const _offsetsMs = [0, 600, 1200];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.stop();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < 3; i++) _ring(i),
          Container(
            width: 104,
            height: 104,
            decoration: const BoxDecoration(
              color: YamColors.avatarBg,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              widget.initial,
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Un anneau : scale 0.85 → 1.9 + fondu, cycle de 2,4 s décalé de 0,6 s.
  Widget _ring(int i) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t =
            ((_ctrl.value * 2400 - _offsetsMs[i]) % 2400 + 2400) % 2400 / 2400;
        final scale = 0.85 + t * 1.05; // → 1.9
        final opacity = 0.5 * (1 - t);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Color.fromRGBO(37, 99, 235, opacity.clamp(0.0, 1.0)),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: Column(
        children: [
          Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 56,
                height: 56,
                child: Icon(icon, color: Colors.white, size: 26),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.white70)),
        ],
      ),
    );
  }
}
