import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:http/http.dart' as http;

/// Handler de fond FCM : appelé quand une notification arrive alors que
/// l'app est en arrière-plan ou fermée. Doit être une fonction top-level
/// (pas de closure) pour être enregistrable par Firebase.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final data = message.data;
  if (!data.containsKey('call_id')) return;

  debugPrint('[YAM][PUSH][BG] Appel entrant en arrière-plan : ${data['from_username']}');

  try {
    final params = CallKitParams(
      id: data['call_id']!,
      nameCaller: data['from_username'] ?? 'Inconnu',
      appName: 'Yam',
      handle: data['from_username'] ?? 'Inconnu',
      type: (data['type'] ?? 'audio') == 'video' ? 1 : 0,
      extra: {
        'call_id': data['call_id'],
        'from_device_id': data['from_device_id'] ?? '',
        'from_username': data['from_username'] ?? 'Inconnu',
        'type': data['type'] ?? 'audio',
      },
    );
    await FlutterCallkitIncoming.showCallkitIncoming(params);
    debugPrint('[YAM][PUSH][BG] Écran CallKit affiché');
  } catch (e) {
    debugPrint('[YAM][PUSH][BG] Erreur affichage CallKit : $e');
  }
}

/// Gestion des notifications push (FCM) pour réveiller l'appareil quand
/// l'application est fermée ou en arrière-plan.
///
/// Sans configuration Firebase (google-services.json), l'initialisation
/// échoue silencieusement : le WebSocket reste le canal principal.
class PushService {
  /// Initialise Firebase et enregistre le token FCM auprès du backend.
  /// Ne lève jamais d'exception : en cas d'échec, on journalise et on continue.
  Future<void> init({
    required String serverUrl,
    required String deviceId,
    required String userName,
    required void Function(Map<String, dynamic>) onIncomingCall,
    Future<void> Function()? onAcceptCall,
  }) async {
    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('[YAM][PUSH] Firebase non configuré, push désactivé : $e');
      return;
    }

    try {
      final messaging = FirebaseMessaging.instance;

      // Handler de fond : affiche l'écran CallKit quand l'app est en
      // arrière-plan ou fermée.
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // Demande la permission de notification (Android 13+).
      final settings = await messaging.requestPermission();
      debugPrint('[YAM][PUSH] Permission notification : ${settings.authorizationStatus}');

      // Récupère le token FCM.
      final token = await messaging.getToken();
      debugPrint('[YAM][PUSH] Token FCM obtenu : ${token != null}');

      if (token != null) {
        await registerDevice(
          serverUrl: serverUrl,
          deviceId: deviceId,
          userName: userName,
          fcmToken: token,
        );
      }

      // Écoute les changements de token (rotation, réinstallation).
      messaging.onTokenRefresh.listen((newToken) {
        debugPrint('[YAM][PUSH] Token FCM rafraîchi');
        registerDevice(
          serverUrl: serverUrl,
          deviceId: deviceId,
          userName: userName,
          fcmToken: newToken,
        );
      });

      // Notification reçue quand l'app est au premier plan.
      FirebaseMessaging.onMessage.listen((message) {
        final data = message.data;
        if (data.containsKey('call_id')) {
          debugPrint('[YAM][PUSH] Appel entrant (foreground) : ${data['from_username']}');
          onIncomingCall(data);
        }
      });

      // Notification tapée quand l'app est en arrière-plan / fermée.
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        final data = message.data;
        if (data.containsKey('call_id')) {
          debugPrint('[YAM][PUSH] Appel entrant (tap) : ${data['from_username']}');
          onIncomingCall(data);
        }
      });

      // Appel entrant quand l'app a été lancée depuis une notification.
      final initial = await messaging.getInitialMessage();
      if (initial?.data.containsKey('call_id') ?? false) {
        debugPrint('[YAM][PUSH] Appel entrant (cold start) : ${initial!.data['from_username']}');
        onIncomingCall(initial.data);
      }

      // Configure l'écran d'appel natif (CallKit) pour les appels entrants
      // quand l'app est en arrière-plan ou fermée.
      _setupCallKit(onIncomingCall, onAcceptCall);

      // Cold start : l'utilisateur a tapé « décrocher » sur l'écran CallKit
      // alors que l'app était tuée. Le plugin rappelle ce handler avec le
      // Map `extra` fourni lors de l'affichage du CallKit.
      FlutterCallkitIncoming.acceptCallHandle((data) {
        debugPrint('[YAM][PUSH] CallKit accept (cold start) : $data');
        final callId = data['call_id'] ?? data['id'] ?? '';
        if (callId.toString().isEmpty) return;
        onIncomingCall({
          'call_id': callId,
          'from_device_id': data['from_device_id'] ?? '',
          'from_username': data['from_username'] ?? 'Inconnu',
          'type': data['type'] ?? 'audio',
        });
        onAcceptCall?.call();
      });
    } catch (e) {
      debugPrint('[YAM][PUSH] Erreur init push : $e');
    }
  }

  /// Configure l'écran d'appel natif (CallKit Android/iOS).
  void _setupCallKit(
    void Function(Map<String, dynamic>) onIncomingCall,
    Future<void> Function()? onAcceptCall,
  ) {
    // Gère les événements CallKit (accept / decline / etc.).
    FlutterCallkitIncoming.onEvent.listen((event) {
      if (event == null) return;
      debugPrint('[YAM][PUSH] CallKit event : ${event.eventName}');

      switch (event) {
        case CallEventActionCallAccept():
          debugPrint('[YAM][PUSH] CallKit : appel accepté');
          final extra = event.callKitParams.extra ?? {};
          onIncomingCall({
            'call_id': event.callKitParams.id,
            'from_device_id': extra['from_device_id'] ?? '',
            'from_username': extra['from_username'] ?? event.callKitParams.nameCaller ?? 'Inconnu',
            'type': extra['type'] ?? 'audio',
          });
          // Accepte directement l'appel (au lieu de re-sonner dans l'app) :
          // l'utilisateur a déjà tapé « décrocher » sur l'écran natif.
          onAcceptCall?.call();
          break;
        case CallEventActionCallDecline():
          debugPrint('[YAM][PUSH] CallKit : appel refusé');
          break;
        case CallEventActionCallEnded():
          debugPrint('[YAM][PUSH] CallKit : appel terminé');
          break;
        case CallEventActionCallTimeout():
          debugPrint('[YAM][PUSH] CallKit : appel expiré');
          break;
        default:
          break;
      }
    });
  }

  /// Affiche l'écran d'appel natif pour un appel entrant.
  Future<void> showIncomingCall({
    required String callId,
    required String fromDeviceId,
    required String fromUsername,
    required String type,
  }) async {
    try {
      final params = CallKitParams(
        id: callId,
        nameCaller: fromUsername,
        appName: 'Yam',
        handle: fromUsername,
        type: type == 'video' ? 1 : 0,
        extra: {
          'call_id': callId,
          'from_device_id': fromDeviceId,
          'from_username': fromUsername,
          'type': type,
        },
      );
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      debugPrint('[YAM][PUSH] Écran CallKit affiché pour $fromUsername');
    } catch (e) {
      debugPrint('[YAM][PUSH] Erreur affichage CallKit : $e');
    }
  }

  /// Termine l'écran d'appel natif.
  Future<void> endCall(String callId) async {
    try {
      await FlutterCallkitIncoming.endCall(callId);
    } catch (e) {
      debugPrint('[YAM][PUSH] Erreur fin CallKit : $e');
    }
  }

  /// Enregistre l'appareil (avec son token FCM) auprès du backend.
  Future<void> registerDevice({
    required String serverUrl,
    required String deviceId,
    required String userName,
    required String fcmToken,
  }) async {
    try {
      final base = serverUrl.replaceAll(RegExp(r'/+$'), '');
      final res = await http
          .post(
            Uri.parse('$base/api/v1/devices/register'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'label': userName,
              'device_id': deviceId,
              'platform': 'android',
              'fcm_token': fcmToken,
            }),
          )
          .timeout(const Duration(seconds: 8));
      debugPrint('[YAM][PUSH] Enregistrement device → HTTP ${res.statusCode}');
    } catch (e) {
      debugPrint('[YAM][PUSH] Échec enregistrement device : $e');
    }
  }
}
