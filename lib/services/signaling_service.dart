import 'dart:async';
import 'dart:convert';

import 'package:dart_pusher_channels/dart_pusher_channels.dart';
import 'package:flutter/foundation.dart';

import 'runtime_config.dart';

enum ConnStatus { connecting, connected, disconnected }

/// Signalisation temps réel via Pusher.com (cluster).
///
/// - La config (app_key + cluster) est chargée à l'exécution depuis
///   `/api/v1/config` (RuntimeConfig) et non plus codée en dur.
/// - Le SDK construit automatiquement l'URL `wss://ws-{cluster}.pusher.com`
///   via `fromCluster` (plus de gestion manuelle hôte/port/schéma).
class SignalingService {
  PusherChannelsClient? _client;
  StreamSubscription<PusherChannelsClientLifeCycleState>? _lifecycleSub;

  void Function(Map<String, dynamic>)? onIncomingCall;
  void Function(Map<String, dynamic>)? onSignal;
  void Function(ConnStatus)? onStatus;

  Future<void> connect({
    required String serverUrl,
    required String deviceId,
    RuntimeConfig? config,
  }) async {
    await disconnect();

    // Trace complète du protocole Pusher (visible dans logcat).
    PusherChannelsPackageLogger.enableLogs();

    // Priorité à la config runtime du backend ; sinon valeurs par défaut.
    final key = config?.pusherKey.isNotEmpty == true ? config!.pusherKey : 'local';
    final cluster = config?.pusherCluster.isNotEmpty == true
        ? config!.pusherCluster
        : 'eu';

    debugPrint('[YAM][WS] connexion Pusher.com → cluster $cluster (clé $key)');

    final client = PusherChannelsClient.websocket(
      options: PusherChannelsOptions.fromCluster(
        scheme: 'wss',
        cluster: cluster,
        key: key,
      ),
      connectionErrorHandler: (exception, trace, refresh) => refresh(),
    );
    _client = client;

    _lifecycleSub = client.lifecycleStream.listen((state) {
      debugPrint('[YAM][WS] état cycle de vie : $state');
      switch (state) {
        case PusherChannelsClientLifeCycleState.establishedConnection:
          onStatus?.call(ConnStatus.connected);
        case PusherChannelsClientLifeCycleState.pendingConnection:
        case PusherChannelsClientLifeCycleState.reconnecting:
        case PusherChannelsClientLifeCycleState.inactive:
          onStatus?.call(ConnStatus.connecting);
        default:
          onStatus?.call(ConnStatus.disconnected);
      }
    });

    // Chaque appareil écoute son propre canal public.
    final channel = client.publicChannel('device.$deviceId');
    channel.bind('incoming-call').listen((event) {
      debugPrint('[YAM][WS] incoming-call reçu : ${event.data}');
      _dispatch(event, onIncomingCall);
    });
    channel.bind('call-signal').listen((event) {
      debugPrint('[YAM][WS] call-signal (${event.name}) reçu');
      _dispatch(event, onSignal);
    });

    // ⚠️ PIÈGE dart_pusher_channels : subscribe() envoie la trame
    // `pusher:subscribe` IMMÉDIATEMENT, sans attendre la connexion.
    // Il faut donc s'abonner APRÈS l'établissement de la connexion,
    // sinon la trame est perdue (contrairement à pusher-js qui la met
    // en file d'attente).
    client.onConnectionEstablished.listen((_) {
      debugPrint(
          '[YAM][WS] connexion établie → abonnement à device.$deviceId');
      channel.subscribe();
    });

    onStatus?.call(ConnStatus.connecting);
    client.connect();
  }

  /// `event.data` est normalement déjà décodé en Map par la lib ; par
  /// prudence on accepte aussi une chaîne JSON brute.
  void _dispatch(
    ChannelReadEvent event,
    void Function(Map<String, dynamic>)? cb,
  ) {
    if (cb == null) return;
    try {
      final raw = event.data;
      if (raw == null) return;
      final Map<String, dynamic> map;
      if (raw is Map<String, dynamic>) {
        map = raw;
      } else if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) return;
        map = decoded;
      } else {
        return;
      }
      cb(map);
    } catch (_) {
      // Payload illisible : ignoré silencieusement.
    }
  }

  Future<void> disconnect() async {
    await _lifecycleSub?.cancel();
    _lifecycleSub = null;
    final c = _client;
    _client = null;
    try {
      await c?.disconnect();
      c?.dispose();
    } catch (_) {}
  }
}