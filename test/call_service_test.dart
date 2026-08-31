import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yam_mobile/services/api_client.dart';
import 'package:yam_mobile/services/call_service.dart';
import 'package:yam_mobile/services/runtime_config.dart';

import 'helpers/native_mocks.dart';

/// Fake d'ApiClient : enregistre les signaux envoyés et permet de piloter la
/// réponse de `fetchDeferredOffer` (l'offre différée du serveur).
class FakeApiClient implements ApiClient {
  @override
  String Function() baseUrlProvider = () => 'http://localhost';

  /// Résultat retourné par fetchDeferredOffer (null = offre introuvable).
  Map<String, dynamic>? deferredOfferResult;

  int fetchDeferredOfferCalls = 0;
  String? lastFetchCallId;
  String? lastFetchDeviceId;

  /// Signaux envoyés : {to, from, type, callId, payload}.
  final List<Map<String, dynamic>> signals = [];

  int get answerCount => signals.where((s) => s['type'] == 'answer').length;
  int get offerCount => signals.where((s) => s['type'] == 'offer').length;
  int get byeCount => signals.where((s) => s['type'] == 'bye').length;

  @override
  Future<Map<String, dynamic>?> fetchDeferredOffer({
    required String callId,
    required String deviceId,
  }) async {
    fetchDeferredOfferCalls++;
    lastFetchCallId = callId;
    lastFetchDeviceId = deviceId;
    return deferredOfferResult;
  }

  @override
  Future<void> signal({
    required String toDeviceId,
    required String fromDeviceId,
    required String type,
    required Map<String, dynamic> payload,
    String? callId,
  }) async {
    signals.add({
      'to': toDeviceId,
      'from': fromDeviceId,
      'type': type,
      'callId': callId,
      'payload': payload,
    });
  }

  @override
  Future<String?> ring({
    required String toDeviceId,
    required String fromDeviceId,
    required String fromUsername,
    String type = 'audio',
  }) async {
    lastRingType = type;
    return 'call-123';
  }

  /// Dernier type passé à ring() ('audio' | 'video').
  String? lastRingType;

  @override
  Future<RuntimeConfig?> fetchConfig() async => null;
}

/// Données d'un appel entrant type (notification push / WebSocket).
const incomingCallData = {
  'call_id': 'call-1',
  'from_device_id': 'dev-peer',
  'from_username': 'Alice',
  'type': 'audio',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeApiClient api;
  late CallService service;
  late WebRtcCallLog webrtcLog;

  setUp(() {
    webrtcLog = WebRtcCallLog();
    installNativeMocks(webrtcLog);
    api = FakeApiClient();
    service = CallService(api);
    service.myDeviceId = 'dev-me';
  });

  group('CallService.accept — offre différée', () {
    test('récupère l\'offre différée quand _pendingOffer est null et rejoint l\'appel', () async {
      // L'offre n'est jamais arrivée en temps réel : le serveur la stocke.
      api.deferredOfferResult = {'sdp': 'v=0\r\no=remote\r\n', 'type': 'offer'};

      await service.handleIncomingCall(incomingCallData);
      expect(service.phase, CallPhase.incoming);

      await service.accept();

      // L'appel est établi.
      expect(service.phase, CallPhase.inCall);
      // L'offre a bien été récupérée avec le call_id et le device local.
      expect(api.fetchDeferredOfferCalls, 1);
      expect(api.lastFetchCallId, 'call-1');
      expect(api.lastFetchDeviceId, 'dev-me');
      // Un seul answer a été émis vers le correspondant.
      expect(api.answerCount, 1);
      final answer = api.signals.firstWhere((s) => s['type'] == 'answer');
      expect(answer['to'], 'dev-peer');
      expect(answer['from'], 'dev-me');
      // Le SDP distant a été appliqué une seule fois.
      expect(webrtcLog.setRemoteDescription, 1);
    });

    test('n\'appelle PAS fetchDeferredOffer quand l\'offre est déjà reçue', () async {
      await service.handleIncomingCall(incomingCallData);

      // L'offre arrive en temps réel pendant la sonnerie → bufferisée.
      await service.handleSignal({
        'from_device_id': 'dev-peer',
        'type': 'offer',
        'payload': {
          'sdp': {'sdp': 'v=0\r\n', 'type': 'offer'},
        },
      });

      await service.accept();

      expect(api.fetchDeferredOfferCalls, 0);
      expect(api.answerCount, 1);
      expect(service.phase, CallPhase.inCall);
    });

    test('abandonne (teardown → idle) quand aucune offre différée n\'est récupérable', () async {
      // 404/403/410/422 ou erreur réseau → fetchDeferredOffer retourne null.
      api.deferredOfferResult = null;

      await service.handleIncomingCall(incomingCallData);
      await service.accept();

      expect(service.phase, CallPhase.idle);
      expect(api.fetchDeferredOfferCalls, 1);
      expect(api.answerCount, 0);
      expect(webrtcLog.setRemoteDescription, 0);
    });

    test('abandonne si l\'offre différée ne contient pas de sdp', () async {
      api.deferredOfferResult = {'type': 'offer'}; // sdp manquant

      await service.handleIncomingCall(incomingCallData);
      await service.accept();

      expect(service.phase, CallPhase.idle);
      expect(api.answerCount, 0);
    });

    test('ne fait rien si l\'appel n\'est pas en phase incoming', () async {
      api.deferredOfferResult = {'sdp': 'v=0\r\n', 'type': 'offer'};

      await service.accept(); // phase idle

      expect(api.fetchDeferredOfferCalls, 0);
      expect(service.phase, CallPhase.idle);
    });
  });

  group('CallService — garde-fou anti-course _answering', () {
    test('deux accept() concurrents ne font qu\'un seul setRemoteDescription et un seul answer', () async {
      api.deferredOfferResult = {'sdp': 'v=0\r\n', 'type': 'offer'};
      await service.handleIncomingCall(incomingCallData);

      // Bloque le premier setRemoteDescription pour garantir que le second
      // accept() arrive pendant que _answering est encore true.
      final gate = Completer<void>();
      final reached = Completer<void>();
      installNativeMocks(
        webrtcLog,
        onSetRemoteDescription: (call) async {
          webrtcLog.setRemoteDescription++;
          if (!reached.isCompleted) reached.complete();
          await gate.future;
          return null;
        },
      );

      final first = service.accept();
      // Attend que le premier accept() soit bloqué sur setRemoteDescription.
      await reached.future;
      final second = service.accept();
      gate.complete();
      await Future.wait([first, second]);

      expect(webrtcLog.setRemoteDescription, 1);
      expect(api.answerCount, 1);
      expect(service.phase, CallPhase.inCall);
    });
  });

  group('CallService — call_id dans les signaux', () {
    test('startOutgoing envoie l\'offre avec le call_id retourné par ring()', () async {
      await service.startOutgoing('dev-peer');

      expect(api.offerCount, 1);
      final offer = api.signals.firstWhere((s) => s['type'] == 'offer');
      expect(offer['callId'], 'call-123');
      expect(offer['to'], 'dev-peer');
      expect(offer['from'], 'dev-me');

      // Termine l'appel pour annuler le timer de timeout (60 s).
      await service.hangUp();
    });

    test('refuse() envoie bye avec le call_id de l\'appel entrant', () async {
      await service.handleIncomingCall(incomingCallData);
      await service.refuse();

      expect(api.byeCount, 1);
      final bye = api.signals.firstWhere((s) => s['type'] == 'bye');
      expect(bye['callId'], 'call-1');
      expect(bye['to'], 'dev-peer');
      expect(service.phase, CallPhase.idle);
    });

    test('hangUp() envoie bye avec le call_id de l\'appel en cours', () async {
      await service.handleIncomingCall(incomingCallData);
      await service.hangUp();

      expect(api.byeCount, 1);
      final bye = api.signals.firstWhere((s) => s['type'] == 'bye');
      expect(bye['callId'], 'call-1');
      expect(service.phase, CallPhase.idle);
    });
  });

  group('CallService — type d\'appel (audio/vidéo)', () {
    test('startOutgoing(video: true) transmet le type video à ring() et active la vidéo', () async {
      await service.startOutgoing('dev-peer', video: true);

      expect(api.lastRingType, 'video');
      expect(service.videoEnabled, true);

      await service.hangUp();
    });

    test('startOutgoing() par défaut transmet le type audio', () async {
      await service.startOutgoing('dev-peer');

      expect(api.lastRingType, 'audio');
      expect(service.videoEnabled, false);

      await service.hangUp();
    });

    test('handleIncomingCall détecte le type video depuis les données', () async {
      await service.handleIncomingCall({
        ...incomingCallData,
        'type': 'video',
      });

      expect(service.videoEnabled, true);
      expect(service.phase, CallPhase.incoming);
    });
  });
}