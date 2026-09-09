import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
  /// Utilisateur appelé pendant la phase d'offre. Le device exact n'est
  /// connu qu'à la réception de l'answer.
  String? targetUserId;
  String? remoteId;
  String? remoteName;
  /// Identifiant utilisateur du correspondant (from_user_id), utile pour le
  /// multi-appareils et l'historique. Peut être null si non fourni.
  String? remoteUserId;
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

  /// Config runtime (Pusher + TURN) chargée depuis le backend.
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
  Timer? _disconnectGraceTimeout;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  final List<RTCIceCandidate> _pendingLocalCandidates = [];

  final AudioPlayer _ringtone = AudioPlayer();

  // ─────────────────────────── Appel sortant ───────────────────────────

  Future<void> startOutgoing(String targetId, {String? targetName, bool video = false}) async {
    final clean = targetId.trim();
    if (phase != CallPhase.idle || clean.isEmpty) return;
    phase = CallPhase.calling;
    targetUserId = clean;
    remoteId = null;
    remoteName = targetName ?? clean;
    videoEnabled = video;
    notifyListeners();
    // Garde l'écran allumé pendant la sonnerie sortante et l'appel.
    unawaited(WakelockPlus.enable());
    try {
      final callId = await _api.ring(
        toUserId: clean,
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
        toUserId: clean,
        fromDeviceId: myDeviceId,
        type: 'offer',
        callId: callId,
        payload: {
          'sdp': {'type': offer.type, 'sdp': offer.sdp},
        },
      );
      unawaited(_startRingback());
      // Si personne ne décroche jamais : on libère tout après 45 s (aligné
      // sur le client web éprouvé).
      _ringTimeout = Timer(const Duration(seconds: 45), () {
        if (phase == CallPhase.calling) hangUp();
      });
    } catch (_) {
      // Le ring a déjà été envoyé : il faut annuler la sonnerie chez la cible
      // avec un bye, sinon elle sonne jusqu'à son propre timeout.
      final rid = remoteId;
      if ((rid != null || targetUserId != null) && currentCallId != null) {
        unawaited(_api.signal(
          toDeviceId: rid,
          toUserId: rid == null ? targetUserId : null,
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
    remoteUserId = data['from_user_id']?.toString();
    currentCallId = data['call_id'] as String?;
    // Le backend envoie `media` (audio|video) pour le type d'appel et `type`
    // (incoming|reject|cancel) pour le type de notification. On lit `media`
    // en premier avec repli sur `type` (aligné sur le client web).
    videoEnabled = (data['media'] ?? data['type'] ?? 'audio') == 'video';
    phase = CallPhase.incoming;
    _pendingOffer = null;
    _acceptRequested = false;
    _answered = false;
    _answering = false;
    notifyListeners();

    // Garde l'écran allumé pendant la sonnerie entrante (l'utilisateur doit
    // voir l'appel et pouvoir décrocher même si l'écran allait s'éteindre).
    unawaited(WakelockPlus.enable());

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
    if (rid != null || remoteUserId != null) {
      // Routage multi-appareils (aligné sur le web) : on envoie le bye au
      // device exact quand on le connaît ET à l'utilisateur cible pour
      // atteindre tous ses appareils (arrêt de la sonnerie partout).
      unawaited(_api.signal(
        toDeviceId: rid,
        toUserId: remoteUserId,
        fromDeviceId: myDeviceId,
        type: 'bye',
        callId: currentCallId,
        payload: {'reason': 'reject'},
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
        final offer = _descriptionFromPayload(payload, fallbackType: 'offer');
        if (offer == null || phase != CallPhase.incoming) return;
        if (_acceptRequested && !_answered && _pc != null) {
          await _answer(offer);
        } else {
          _pendingOffer = offer; // bufferisé (pendant la sonnerie ou avant _pc)
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
        final answer = _descriptionFromPayload(payload, fallbackType: 'answer');
        // Garde-fou : l'appelant peut renvoyer l'answer plusieurs fois (envois
        // répétés côté web). Un second setRemoteDescription ferait échouer
        // l'appel → on ignore toute answer une fois _answered.
        if (_pc == null || answer == null || _answered) return;
        try {
          // Le premier answer révèle le device qui a décroché parmi les
          // appareils de l'utilisateur cible.
          remoteId = data['from_device_id']?.toString();
          await _pc!.setRemoteDescription(answer);
          _answered = true;
          await _flushLocalCandidates();
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
        // Un bye signifie que l'autre partie a raccroché ou refusé.
        // Il faut le traiter MÊME si remoteId est null (appelant qui n'a pas
        // encore reçu l'answer, ou appelé qui n'a pas encore répondu) :
        // sinon l'appelant continue de sonner jusqu'à son propre timeout.
        if (phase == CallPhase.idle) break;
        final from = data['from_device_id']?.toString();
        // Vérifie que le bye vient bien du correspondant courant, quand on le
        // connaît. Un bye d'un device tiers (autre appareil du destinataire
        // qui décline pendant qu'un autre répond) est ignoré pour ne pas tuer
        // l'appel en cours d'établissement.
        if (remoteId != null && from != null && remoteId != from) break;
        // Quand remoteId est null (pas encore d'answer), on protège contre un
        // bye spoofé d'un autre device en vérifiant le call_id : le bye doit
        // concerner notre appel courant. Un bye legacy (sans from_device_id)
        // est accepté tant que le call_id correspond (aligné sur le web).
        if (remoteId == null) {
          final byeCallId = data['call_id']?.toString();
          if (byeCallId != null && byeCallId.isNotEmpty &&
              currentCallId != null && byeCallId != currentCallId) {
            break;
          }
        }
        {
          final rid = remoteId ?? from ?? '';
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
    // Le device du correspondant doit être connu pour router l'answer.
    final peerId = remoteId;
    if (peerId == null) {
      debugPrint('[YAM][CALL] _answer appelé sans remoteId → abandon');
      await teardown();
      return;
    }
    _answering = true;
    try {
      await _pc!.setRemoteDescription(offer);
      await _drainCandidates();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _api.signal(
        toDeviceId: peerId,
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

  Future<void> hangUp() async {
    if (phase == CallPhase.idle) return;
    final rid = remoteId;
    final rname = remoteName ?? rid ?? '';
    final wasInCall = phase == CallPhase.inCall;
    // Si on annule un appel sortant avant réponse, on prévient la cible
    // (reason=cancel) pour qu'elle arrête de sonner.
    final wasCalling = phase == CallPhase.calling;
    if (rid != null || remoteUserId != null || targetUserId != null) {
      // Routage multi-appareils (aligné sur le web) : on envoie le bye au
      // device exact quand on le connaît ET à l'utilisateur cible pour
      // atteindre tous ses appareils (arrêt de la sonnerie partout).
      unawaited(_api.signal(
        toDeviceId: rid,
        toUserId: remoteUserId ?? targetUserId,
        fromDeviceId: myDeviceId,
        type: 'bye',
        callId: currentCallId,
        payload: wasCalling ? {'reason': 'cancel'} : {},
      ).catchError((_) {}));
    }
    await teardown();
    if (rid != null && wasInCall) onCallEnded?.call(rid, rname, false);
  }

  /// Libère TOUT : sonnerie, vibration, PeerConnection, pistes micro, état.
  Future<void> teardown() async {
    _stopRing();
    unawaited(Vibration.cancel());
    // L'appel est terminé : l'écran peut se rendormir.
    unawaited(WakelockPlus.disable());
    _ringTimeout?.cancel();
    _disconnectGraceTimeout?.cancel();
    _disconnectGraceTimeout = null;
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
    _pendingLocalCandidates.clear();
    micMuted = false;
    speakerOn = true;
    cameraOn = false;
    videoEnabled = false;
    phase = CallPhase.idle;
    remoteId = null;
    targetUserId = null;
    remoteName = null;
    remoteUserId = null;
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
      if (cand.candidate == null) return;
      if (remoteId == null) {
        _pendingLocalCandidates.add(cand);
      } else {
        _sendCandidate(cand);
      }
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
        // appel qui aurait remplacé `_pc` pendant le délai.
        // Le timer est tracké et annulé dès que l'appel reprend (connected)
        // ou est libéré (teardown), sinon un appel valide serait tué par un
        // délai de grâce résiduel (bug web corrigé, aligné ici : 5 s).
        final captured = pc;
        _disconnectGraceTimeout?.cancel();
        _disconnectGraceTimeout = Timer(const Duration(seconds: 5), () {
          if (identical(_pc, captured) &&
              captured.connectionState ==
                  RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
            unawaited(teardown());
          }
        });
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        // L'appel a repris : annule le délai de grâce en cours.
        _disconnectGraceTimeout?.cancel();
        _disconnectGraceTimeout = null;
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

  void _sendCandidate(RTCIceCandidate candidate) {
    final rid = remoteId;
    if (rid == null) return;
    unawaited(_api.signal(
      toDeviceId: rid,
      fromDeviceId: myDeviceId,
      type: 'candidate',
      callId: currentCallId,
      payload: {
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      },
    ));
  }

  Future<void> _flushLocalCandidates() async {
    for (final candidate in List<RTCIceCandidate>.of(_pendingLocalCandidates)) {
      _sendCandidate(candidate);
    }
    _pendingLocalCandidates.clear();
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
    if (payload == null) return null;
    return _descriptionFromPayload(payload, fallbackType: 'offer');
  }

  RTCSessionDescription? _descriptionFromPayload(
    Map<String, dynamic> payload, {
    required String fallbackType,
  }) {
    final rawSdp = payload['sdp'];
    if (rawSdp is String && rawSdp.isNotEmpty) {
      return RTCSessionDescription(sdpNormalise(rawSdp), payload['type']?.toString() ?? fallbackType);
    }
    if (rawSdp is Map) {
      final nested = rawSdp.cast<String, dynamic>();
      final sdp = nested['sdp']?.toString();
      if (sdp == null || sdp.isEmpty) return null;
      return RTCSessionDescription(sdpNormalise(sdp), nested['type']?.toString() ?? fallbackType);
    }
    return null;
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
