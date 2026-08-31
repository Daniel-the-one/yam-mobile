import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import 'api_client.dart';
import 'runtime_config.dart';

enum CallPhase { idle, calling, incoming, inCall }

/// Machine à états d'un appel audio de bout en bout.
///
/// Points critiques hérités du client web éprouvé :
/// - L'offre reçue pendant la sonnerie est BUFFERISÉE (pas encore de
///   PeerConnection à ce stade).
/// - Les candidates ICE distantes arrivant trop tôt sont mises en file.
/// - Le backend Laravel tronque le `\r\n` final du SDP → normalisation
///   OBLIGATOIRE avant chaque setRemoteDescription, sinon « Invalid SDP line ».
class CallService extends ChangeNotifier {
  CallService(this._api);

  final ApiClient _api;

  CallPhase phase = CallPhase.idle;
  String? remoteId;
  String? remoteName;
  bool micMuted = false;
  bool speakerOn = true;
  bool cameraOn = false;
  bool videoEnabled = false;

  /// Identifiant de l'appel courant (pour synchroniser l'écran CallKit natif).
  String? currentCallId;

  /// Streams média exposés pour l'UI (rendu vidéo).
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  String myDeviceId = '';
  String myName = 'Moi';

  /// Config runtime (Reverb + TURN) chargée depuis le backend.
  RuntimeConfig? config;

  /// Notifié à la fin d'un appel pour alimentation de l'historique.
  void Function(String peerId, String peerName, bool missed)? onCallEnded;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCSessionDescription? _pendingOffer;
  bool _acceptRequested = false;
  bool _answered = false;
  bool _answering = false;
  Timer? _ringTimeout;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  final AudioPlayer _ringtone = AudioPlayer();

  // ─────────────────────────── Appel sortant ───────────────────────────

  Future<void> startOutgoing(String targetId, {bool video = false}) async {
    final clean = targetId.trim();
    if (phase != CallPhase.idle || clean.isEmpty) return;
    phase = CallPhase.calling;
    remoteId = clean;
    remoteName = clean;
    videoEnabled = video;
    notifyListeners();
    try {
      final callId = await _api.ring(
        toDeviceId: clean,
        fromDeviceId: myDeviceId,
        fromUsername: myName,
        type: video ? 'video' : 'audio',
      );
      currentCallId = callId;
      await _ensureMedia(video: video);
      await _createPeer(video: video);
      final offerConstraints = {
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': video,
      };
      final offer = await _pc!.createOffer(offerConstraints);
      await _pc!.setLocalDescription(offer);
      await _api.signal(
        toDeviceId: clean,
        fromDeviceId: myDeviceId,
        type: 'offer',
        callId: callId,
        payload: {
          'sdp': {'type': offer.type, 'sdp': offer.sdp},
        },
      );
      unawaited(_startRingback());
      // Si personne ne décroche jamais : on libère tout après 60 s.
      _ringTimeout = Timer(const Duration(seconds: 60), () {
        if (phase == CallPhase.calling) hangUp();
      });
    } catch (_) {
      // Le ring a déjà été envoyé : il faut annuler la sonnerie chez la cible
      // avec un bye, sinon elle sonne jusqu'à son propre timeout.
      final rid = remoteId;
      if (rid != null && currentCallId != null) {
        unawaited(_api.signal(
          toDeviceId: rid,
          fromDeviceId: myDeviceId,
          type: 'bye',
          callId: currentCallId,
          payload: {},
        ).catchError((_) {}));
      }
      await teardown();
      rethrow;
    }
  }

  // ─────────────────────────── Appel entrant ───────────────────────────

  Future<void> handleIncomingCall(Map<String, dynamic> data) async {
    debugPrint('[YAM][CALL] incoming-call → $data');
    if (phase != CallPhase.idle) return; // occupé : on ignore
    remoteId = data['from_device_id'] as String?;
    remoteName = (data['from_username'] as String?) ?? remoteId ?? 'Inconnu';
    currentCallId = data['call_id'] as String?;
    videoEnabled = (data['type'] as String?) == 'video';
    phase = CallPhase.incoming;
    _pendingOffer = null;
    _acceptRequested = false;
    _answered = false;
    _answering = false;
    notifyListeners();

    unawaited(_startRingtone());
    unawaited(Vibration.hasVibrator().then((ok) {
      if (ok == true) {
        Vibration.vibrate(pattern: [400, 200, 400, 200, 400], repeat: 0);
      }
    }));
  }

  Future<void> accept() async {
    if (phase != CallPhase.incoming) return;
    _stopRing();
    _acceptRequested = true;
    notifyListeners();
    try {
      await _ensureMedia(video: videoEnabled);
      await _createPeer(video: videoEnabled);
      final offer = _pendingOffer;
      if (offer != null) {
        await _answer(offer);
      } else {
        // Offre non reçue en temps réel (appelé hors ligne, reconnexion) :
        // la récupérer depuis le stockage différé du serveur.
        final recovered = await _fetchDeferredOffer();
        if (recovered != null) {
          await _answer(recovered);
        } else {
          // Offre introuvable / expirée : l'appelant a probablement raccroché.
          debugPrint('[YAM][CALL] Aucune offre différée récupérable → abandon');
          await teardown();
        }
      }
    } catch (_) {
      await teardown();
      rethrow;
    }
  }

  Future<void> refuse() async {
    if (phase != CallPhase.incoming) return;
    final rid = remoteId;
    final rname = remoteName ?? rid ?? '';
    if (rid != null) {
      unawaited(_api.signal(
        toDeviceId: rid,
        fromDeviceId: myDeviceId,
        type: 'bye',
        callId: currentCallId,
        payload: {},
      ).catchError((_) {}));
    }
    await teardown();
    if (rid != null) onCallEnded?.call(rid, rname, true);
  }

  // ─────────────────────── Signalisation reçue ─────────────────────────

  Future<void> handleSignal(Map<String, dynamic> data) async {
    if (data['from_device_id'] == myDeviceId) return;
    final type = data['type'] as String?;
    final payload =
        ((data['payload'] as Map?)?.cast<String, dynamic>()) ?? const {};

    switch (type) {
      case 'offer':
        final sdpMap = (payload['sdp'] as Map?)?.cast<String, dynamic>();
        if (sdpMap == null || phase != CallPhase.incoming) return;
        final desc = RTCSessionDescription(
          sdpNormalise(sdpMap['sdp'] as String),
          sdpMap['type'] as String,
        );
        if (_acceptRequested && !_answered && _pc != null) {
          await _answer(desc);
        } else {
          _pendingOffer = desc; // bufferisé (pendant la sonnerie ou avant _pc)
        }
        break;

      case 'candidate':
        final c = (payload['candidate'] as Map?)?.cast<String, dynamic>();
        if (c == null || c['candidate'] == null) return;
        final cand = RTCIceCandidate(
          c['candidate'] as String,
          c['sdpMid'] as String?,
          (c['sdpMLineIndex'] as num?)?.toInt(),
        );
        if (_answered && _pc != null) {
          try {
            await _pc!.addCandidate(cand);
          } catch (e) {
            debugPrint('[YAM][CALL] addCandidate ignoré : $e');
          }
        } else {
          _pendingRemoteCandidates.add(cand); // arrivée trop tôt : en file
        }
        break;

      case 'answer':
        final sdpMap = (payload['sdp'] as Map?)?.cast<String, dynamic>();
        // Garde-fou : l'appelant peut renvoyer l'answer plusieurs fois (envois
        // répétés côté web). Un second setRemoteDescription ferait échouer
        // l'appel → on ignore toute answer une fois _answered.
        if (_pc == null || sdpMap == null || _answered) return;
        try {
          await _pc!.setRemoteDescription(
            RTCSessionDescription(
              sdpNormalise(sdpMap['sdp'] as String),
              sdpMap['type'] as String,
            ),
          );
          _answered = true;
          _stopRing();
          await _drainCandidates();
          await Helper.setSpeakerphoneOn(speakerOn);
          phase = CallPhase.inCall;
          _ringTimeout?.cancel();
          notifyListeners();
        } catch (e) {
          debugPrint('[YAM][CALL] Erreur setRemoteDescription (answer) : $e');
          await teardown();
        }
        break;

      case 'bye':
        if (remoteId != null && remoteId == data['from_device_id']) {
          final rid = remoteId!;
          final rname = remoteName ?? rid;
          final wasInCall = phase == CallPhase.inCall;
          final wasIncoming = phase == CallPhase.incoming;
          await teardown();
          if (wasInCall) {
            onCallEnded?.call(rid, rname, false);
          } else if (wasIncoming) {
            onCallEnded?.call(rid, rname, true);
          }
        }
        break;
    }
  }

  Future<void> _answer(RTCSessionDescription offer) async {
    // Garde-fou anti-course : l'offre peut arriver par WebSocket PENDANT la
    // récupération différée (fetchDeferredOffer). Deux _answer entrelacés
    // feraient échouer le second setRemoteDescription → appel tué.
    if (_pc == null || _answered || _answering) return;
    _answering = true;
    try {
      await _pc!.setRemoteDescription(offer);
      await _drainCandidates();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _api.signal(
        toDeviceId: remoteId!,
        fromDeviceId: myDeviceId,
        type: 'answer',
        payload: {
          'sdp': {'type': answer.type, 'sdp': answer.sdp},
        },
      );
      _answered = true;
      await Helper.setSpeakerphoneOn(speakerOn);
      phase = CallPhase.inCall;
      notifyListeners();
    } finally {
      _answering = false;
    }
  }

  // ────────────────────────── Fin d'appel ──────────────────────────────

  Future<void> hangUp() async {
    if (phase == CallPhase.idle) return;
    final rid = remoteId;
    final rname = remoteName ?? rid ?? '';
    final wasInCall = phase == CallPhase.inCall;
    if (rid != null) {
      unawaited(_api.signal(
        toDeviceId: rid,
        fromDeviceId: myDeviceId,
        type: 'bye',
        callId: currentCallId,
        payload: {},
      ).catchError((_) {}));
    }
    await teardown();
    if (rid != null && wasInCall) onCallEnded?.call(rid, rname, false);
  }

  /// Libère TOUT : sonnerie, vibration, PeerConnection, pistes micro, état.
  Future<void> teardown() async {
    _stopRing();
    unawaited(Vibration.cancel());
    _ringTimeout?.cancel();
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try {
      _remoteStream?.getTracks().forEach((t) => t.stop());
      await _remoteStream?.dispose();
    } catch (_) {}
    _remoteStream = null;
    _pendingOffer = null;
    _acceptRequested = false;
    _answered = false;
    _answering = false;
    _pendingRemoteCandidates.clear();
    micMuted = false;
    speakerOn = true;
    cameraOn = false;
    videoEnabled = false;
    phase = CallPhase.idle;
    remoteId = null;
    remoteName = null;
    currentCallId = null;
    notifyListeners();
  }

  // ─────────────────────────── Contrôles ───────────────────────────────

  void toggleMute() {
    micMuted = !micMuted;
    for (final t in _localStream?.getAudioTracks() ?? const []) {
      t.enabled = !micMuted;
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    await Helper.setSpeakerphoneOn(speakerOn);
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    if (!videoEnabled) return;
    cameraOn = !cameraOn;
    for (final t in _localStream?.getVideoTracks() ?? const []) {
      t.enabled = cameraOn;
    }
    // NB : on ne rétrograde pas l'appel en mode audio ici. Couper la caméra
    // n'arrête pas le flux distant ; l'UI affiche un placeholder « caméra
    // coupée » sur la vignette locale tant que cameraOn == false.
    notifyListeners();
  }

  // ─────────────────────────── Internes ────────────────────────────────

  Future<void> _ensureMedia({bool video = false}) async {
    if (_localStream != null) return;
    final st = await Permission.microphone.request();
    if (!st.isGranted) throw Exception('Permission micro refusée');
    if (video) {
      final camSt = await Permission.camera.request();
      if (!camSt.isGranted) throw Exception('Permission caméra refusée');
    }
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video,
    });
    if (video) cameraOn = true;
  }

  Future<void> _createPeer({bool video = false}) async {
    if (_pc != null) return;
    final pc = await createPeerConnection({
      'iceServers': config?.iceServers ??
          [
            {
              'urls': [
                'stun:stun.l.google.com:19302',
                'stun:stun1.l.google.com:19302',
                'stun:stun2.l.google.com:19302',
              ]
            },
            {'urls': ['stun:stun.cloudflare.com:3478']},
          ],
      'sdpSemantics': 'unified-plan',
    });

    pc.onIceCandidate = (cand) {
      final rid = remoteId;
      if (cand.candidate == null || rid == null) return;
      unawaited(_api.signal(
        toDeviceId: rid,
        fromDeviceId: myDeviceId,
        type: 'candidate',
        payload: {
          'candidate': {
            'candidate': cand.candidate,
            'sdpMid': cand.sdpMid,
            'sdpMLineIndex': cand.sdpMLineIndex,
          },
        },
      ));
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        // Libérer l'ancien flux distant avant de le remplacer (renegotiation).
        final prev = _remoteStream;
        _remoteStream = event.streams.first;
        if (prev != null && prev != _remoteStream) {
          try {
            prev.getTracks().forEach((t) => t.stop());
            prev.dispose();
          } catch (_) {}
        }
        notifyListeners();
      }
    };

    pc.onConnectionState = (state) {
      // Détection de fin d'appel côté correspondant (pas de signal hangup).
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        unawaited(teardown());
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // Délai de grâce : en vidéo les flux sont plus lourds et les coupures
        // transitoires (Wi-Fi → 4G, rotation) sont fréquentes. Laisser le
        // temps à ICE de se reconnecter avant de tuer l'appel.
        // On capture `pc` (pas `_pc`) pour ne pas tuer un éventuel nouvel
        // appel qui aurait remplacé `_pc` pendant les 5 s.
        final captured = pc;
        Future.delayed(const Duration(seconds: 5), () {
          if (identical(_pc, captured) &&
              captured.connectionState ==
                  RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
            unawaited(teardown());
          }
        });
      }
    };

    final local = _localStream;
    if (local != null) {
      for (final track in local.getTracks()) {
        await pc.addTrack(track, local);
      }
    }
    _pc = pc;
  }

  Future<void> _drainCandidates() async {
    final pc = _pc;
    if (pc == null) return;
    for (final c in List.of(_pendingRemoteCandidates)) {
      try {
        await pc.addCandidate(c);
      } catch (e) {
        debugPrint('[YAM][CALL] Candidate différé ignoré : $e');
      }
    }
    _pendingRemoteCandidates.clear();
  }

  /// Récupère l'offre SDP différée stockée par le serveur (GET
  /// /call/{call_id}/offer) quand elle n'a pas été reçue en temps réel.
  Future<RTCSessionDescription?> _fetchDeferredOffer() async {
    final callId = currentCallId;
    if (callId == null || callId.isEmpty) return null;
    debugPrint('[YAM][CALL] Récupération de l\'offre différée ($callId)...');
    final payload = await _api.fetchDeferredOffer(
      callId: callId,
      deviceId: myDeviceId,
    );
    if (payload == null || payload['sdp'] == null) return null;
    return RTCSessionDescription(
      sdpNormalise(payload['sdp'] as String),
      payload['type'] as String? ?? 'offer',
    );
  }

  Future<void> _startRingback() async {
    try {
      await _ringtone.stop();
      await _ringtone.setReleaseMode(ReleaseMode.loop);
      // Sonnerie de sortie (tonalité d'attente) : freesound_community-ring-tone-68676
      await _ringtone.play(AssetSource('sounds/freesound_community-ring-tone-68676 (1).mp3'));
      debugPrint('[YAM][RINGBACK] sonnerie de sortie démarrée');
    } catch (e) {
      debugPrint('[YAM][RINGBACK] ERREUR sonnerie de sortie : $e');
    }
  }

  Future<void> _startRingtone() async {
    try {
      await _ringtone.stop();
      await _ringtone.setReleaseMode(ReleaseMode.loop);
      await _ringtone.play(AssetSource('sounds/ringtone.mp3'));
      debugPrint('[YAM][RING] sonnerie démarrée');
    } catch (e) {
      debugPrint('[YAM][RING] ERREUR sonnerie : $e');
    }
  }

  void _stopRing() {
    debugPrint('[YAM][RING] arrêt sonnerie / tonalité');
    try {
      unawaited(_ringtone.stop());
    } catch (_) {}
  }
}

/// ⚠️ PIÈGE CRITIQUE : Laravel supprime le `\r\n` final du SDP pendant le
/// broadcast. Sans ce correctif : « Invalid SDP line » et AUCUN appel.
String sdpNormalise(String sdp) => sdp.endsWith('\r\n') ? sdp : '$sdp\r\n';
