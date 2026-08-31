import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_service.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Écran d'appel actif : vidéo distante plein écran, PIP locale, controls.
/// En mode audio-only : avatar + timer + controls (comportement original).
class InCallScreen extends StatefulWidget {
  const InCallScreen({super.key, required this.app});

  final AppState app;

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  Timer? _timer;
  DateTime? _start;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _renderersInitialized = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    // Si le widget a été disposé pendant l'await, `dispose()` a déjà libéré
    // les renderers → ne pas les disposer une seconde fois (double dispose).
    if (_disposed) return;
    if (mounted) {
      setState(() => _renderersInitialized = true);
      _syncRenderers();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  /// Synchronise les renderers avec les streams du CallService.
  void _syncRenderers() {
    final call = widget.app.call;
    final local = call.localStream;
    final remote = call.remoteStream;
    if (_localRenderer.srcObject != local) {
      _localRenderer.srcObject = local;
    }
    if (_remoteRenderer.srcObject != remote) {
      _remoteRenderer.srcObject = remote;
    }
  }

  String get _elapsed {
    final start = _start;
    if (start == null) return '00:00';
    final s = DateTime.now().difference(start).inSeconds;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.app.call;
    final waiting = call.phase == CallPhase.calling;
    if (!waiting && _start == null) _start = DateTime.now();

    // Synchroniser les renderers à chaque rebuild.
    if (_renderersInitialized) _syncRenderers();

    final isVideo = call.videoEnabled &&
        call.phase == CallPhase.inCall &&
        _renderersInitialized &&
        call.remoteStream != null;

    if (isVideo) {
      return _buildVideoMode(call, waiting);
    }
    return _buildAudioMode(call, waiting);
  }

  // ─────────────────── Mode vidéo (plein écran) ──────────────────────

  Widget _buildVideoMode(CallService call, bool waiting) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Vidéo distante en plein écran.
          Positioned.fill(
            child: RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),

          // Mini-vue locale en haut à droite.
          if (call.localStream != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              right: 16,
              width: 120,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RTCVideoView(
                        _localRenderer,
                        mirror: true,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                      // Placeholder quand la caméra est coupée.
                      if (!call.cameraOn)
                        const ColoredBox(
                          color: Colors.black87,
                          child: Center(
                            child: Icon(
                              Icons.videocam_off_rounded,
                              color: Colors.white54,
                              size: 32,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

          // Overlay haut : nom + timer.
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  call.remoteName ?? '',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  waiting ? 'Sonnerie…' : _elapsed,
                  style: mono(size: 14, color: Colors.white70),
                ),
              ],
            ),
          ),

          // Controls en bas.
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            left: 0,
            right: 0,
            child: _buildVideoControls(call),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoControls(CallService call) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _CtrlButton(
              icon: call.speakerOn
                  ? Icons.volume_up_rounded
                  : Icons.volume_off_rounded,
              label: call.speakerOn ? 'Haut-parleur' : 'Écouteur',
              onTap: call.toggleSpeaker,
            ),
            const SizedBox(width: 18),
            _CtrlButton(
              icon: call.micMuted
                  ? Icons.mic_off_rounded
                  : Icons.mic_rounded,
              label: call.micMuted ? 'Activer le micro' : 'Couper le micro',
              highlight: !call.micMuted,
              onTap: call.toggleMute,
            ),
            const SizedBox(width: 18),
            _CtrlButton(
              icon: call.cameraOn
                  ? Icons.videocam_rounded
                  : Icons.videocam_off_rounded,
              label: call.cameraOn ? 'Couper la caméra' : 'Activer la caméra',
              highlight: call.cameraOn,
              onTap: call.toggleCamera,
            ),
          ],
        ),
        const SizedBox(height: 32),
        Material(
          color: YamColors.danger,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: call.hangUp,
            child: const SizedBox(
              width: 64,
              height: 64,
              child: Icon(Icons.call_end_rounded,
                  color: Colors.white, size: 30),
            ),
          ),
        ),
      ],
    );
  }

  // ─────────────────── Mode audio (comportement original) ────────────

  Widget _buildAudioMode(CallService call, bool waiting) {
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
            Text(
              waiting ? 'APPEL EN COURS' : 'EN COMMUNICATION',
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w600,
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              waiting ? 'Sonnerie…' : _elapsed,
              style: mono(size: 30, color: Colors.white),
            ),
            const SizedBox(height: 28),
            Container(
              width: 104,
              height: 104,
              decoration: const BoxDecoration(
                color: YamColors.avatarBg,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                _initial(call.remoteName),
                style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w600,
                    color: Colors.white),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              call.remoteName ?? '',
              style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(call.remoteId ?? '',
                style: mono(size: 13, color: Colors.white38)),
            const SizedBox(height: 44),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CtrlButton(
                  icon: call.speakerOn
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                  label: call.speakerOn ? 'Haut-parleur' : 'Écouteur',
                  onTap: call.toggleSpeaker,
                ),
                const SizedBox(width: 18),
                _CtrlButton(
                  icon: call.micMuted
                      ? Icons.mic_off_rounded
                      : Icons.mic_rounded,
                  label: call.micMuted ? 'Activer le micro' : 'Couper le micro',
                  highlight: !call.micMuted,
                  onTap: call.toggleMute,
                ),
                const SizedBox(width: 18),
                const _CtrlButton(
                  icon: Icons.dialpad_rounded,
                  label: 'Clavier',
                ),
              ],
            ),
            const SizedBox(height: 44),
            Material(
              color: YamColors.danger,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: call.hangUp,
                child: const SizedBox(
                  width: 64,
                  height: 64,
                  child: Icon(Icons.call_end_rounded,
                      color: Colors.white, size: 30),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _initial(String? name) {
    final n = name ?? '';
    return n.isEmpty ? '?' : n.substring(0, 1).toUpperCase();
  }
}

class _CtrlButton extends StatelessWidget {
  const _CtrlButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// true = micro actif (pastille bleue), false = coupé (pastille rouge).
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final bg = onTap == null
        ? const Color.fromRGBO(255, 255, 255, 0.08)
        : highlight
            ? YamColors.accent
            : const Color.fromRGBO(255, 255, 255, 0.12);
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(icon, color: Colors.white, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}
