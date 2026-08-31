import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:vibration_platform_interface/vibration_platform_interface.dart';

/// Compteur des appels natifs WebRTC importants pour la logique testée.
///
/// Permet de vérifier les garde-fous (ex. un seul `setRemoteDescription`
/// malgré deux `accept()` concurrents) sans dépendre d'un mock d'objet.
class WebRtcCallLog {
  int createPeerConnection = 0;
  int getUserMedia = 0;
  int createOffer = 0;
  int createAnswer = 0;
  int setRemoteDescription = 0;
}

/// Fake de la plateforme permission_handler : la permission micro est
/// toujours accordée (aucun appel natif réel).
class FakePermissionHandler extends PermissionHandlerPlatform {
  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) async =>
      PermissionStatus.granted;

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async =>
      {for (final p in permissions) p: PermissionStatus.granted};
}

/// Fake de la plateforme vibration : vibreur présent, aucune vibration réelle.
class FakeVibrationPlatform extends VibrationPlatform {
  @override
  Future<bool> hasVibrator() async => true;

  @override
  Future<bool> hasAmplitudeControl() async => false;

  @override
  Future<bool> hasCustomVibrationsSupport() async => false;

  @override
  Future<void> vibrate({
    int duration = 500,
    List<int> pattern = const [],
    int repeat = -1,
    List<int> intensities = const [],
    int amplitude = -1,
    double sharpness = 0.5,
  }) async {}

  @override
  Future<void> cancel() async {}
}

/// Réponse native par défaut pour une méthode du channel flutter_webrtc.
///
/// Les formats reproduisent exactement ce que renvoie le plugin natif
/// (voir flutter_webrtc/lib/src/native/) : `createPeerConnection` attend
/// `{peerConnectionId}`, `getUserMedia` attend `{streamId, audioTracks,
/// videoTracks}`, `addTrack` attend un `RTCRtpSender` sérialisé, etc.
Future<Object?> defaultWebRtcResponse(MethodCall call, WebRtcCallLog log) async {
  switch (call.method) {
    case 'createPeerConnection':
      log.createPeerConnection++;
      return {'peerConnectionId': 'pc-test'};
    case 'getUserMedia':
      log.getUserMedia++;
      return {
        'streamId': 'stream-test',
        'audioTracks': [
          {
            'id': 'track-audio',
            'label': 'micro',
            'kind': 'audio',
            'enabled': true,
          },
        ],
        'videoTracks': <dynamic>[],
      };
    case 'addTrack':
      // RTCRtpSenderNative.fromMap exige encodings/headerExtensions/codecs
      // et rtcp non-null (RTCRtpParameters.fromMap).
      return {
        'senderId': 'sender-test',
        'track': <dynamic, dynamic>{},
        'rtpParameters': <dynamic, dynamic>{
          'encodings': <dynamic>[],
          'headerExtensions': <dynamic>[],
          'codecs': <dynamic>[],
          'rtcp': <dynamic, dynamic>{
            'reducedSize': false,
          },
        },
        'ownsTrack': false,
      };
    case 'createOffer':
      log.createOffer++;
      return {'sdp': 'v=0\r\no=offer 1 1 IN IP4 0.0.0.0\r\n', 'type': 'offer'};
    case 'createAnswer':
      log.createAnswer++;
      return {'sdp': 'v=0\r\no=answer 1 1 IN IP4 0.0.0.0\r\n', 'type': 'answer'};
    case 'setRemoteDescription':
      log.setRemoteDescription++;
      return null;
    case 'setLocalDescription':
    case 'close':
    case 'enableSpeakerphone':
    case 'trackDispose':
    case 'streamDispose':
      return null;
    default:
      return null;
  }
}

/// Installe tous les mocks natifs nécessaires à `CallService` :
///
///  - MethodChannel `FlutterWebRTC.Method` (création PeerConnection, SDP,
///    audio) — les instances natives de flutter_webrtc étant `static final`,
///    le mock du channel est la seule porte d'entrée propre ;
///  - EventChannel des événements PeerConnection (répond au `listen` initial
///    pour éviter une MissingPluginException) ;
///  - channels audioplayers (`xyz.luan/audioplayers[.global]`) en no-op ;
///  - plateformes permission_handler et vibration remplacées par des fakes.
///
/// [onSetRemoteDescription] : hook optionnel pour contrôler le moment où le
/// premier `setRemoteDescription` est exécuté (tests de concurrence).
void installNativeMocks(
  WebRtcCallLog log, {
  Future<Object?> Function(MethodCall call)? onSetRemoteDescription,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(
    const MethodChannel('FlutterWebRTC.Method'),
    (call) async {
      if (call.method == 'setRemoteDescription' &&
          onSetRemoteDescription != null) {
        return onSetRemoteDescription(call);
      }
      return defaultWebRtcResponse(call, log);
    },
  );

  // Le constructeur de RTCPeerConnectionNative écoute cet EventChannel :
  // répondre au 'listen' évite une MissingPluginException non gérée.
  messenger.setMockMethodCallHandler(
    const MethodChannel('FlutterWebRTC/peerConnectionEventpc-test'),
    (call) async => null,
  );

  // audioplayers : tous les appels sont des no-op (sonnerie/ringback).
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (call) async => null,
  );

  // Plateformes natives remplacées par des fakes en mémoire.
  PermissionHandlerPlatform.instance = FakePermissionHandler();
  VibrationPlatform.instance = FakeVibrationPlatform();
}