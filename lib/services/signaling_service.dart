import 'dart:async';
import 'dart:convert';

import 'package:dart_pusher_channels/dart_pusher_channels.dart';
import 'package:flutter/foundation.dart';

import 'runtime_config.dart';

enum ConnStatus { connecting, connected, disconnected }

/// Signalisation temps réel via Reverb (protocole Pusher).
///
/// - La config (hôte, port, schéma, clé) est chargée à l'exécution depuis
///   `/api/v1/config` (RuntimeConfig) et non plus codée en dur.
/// - Le cluster n'est pas utilisé : on attaque l'hôte directement
///   (`fromHost`, pas `fromCluster`).
/// - HTTPS → wss:443 (mode tunnel), sinon ws:hôte:port fourni.
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

    final uri = Uri.parse(serverUrl);
    final secure = uri.scheme == 'https';

    // Priorité à la config runtime du backend ; sinon valeurs par défaut.
    // Le backend expose un schéma HTTP (http/https) : on le convertit en
    // schéma WebSocket (ws/wss).
    final rawScheme = config?.reverbScheme.isNotEmpty == true
        ? config!.reverbScheme
        : (secure ? 'https' : 'http');
    final scheme = rawScheme == 'https' ? 'wss' : 'ws';
    final host = config?.reverbHost.isNotEmpty == true
        ? config!.reverbHost
        : uri.host;
    final port = config?.reverbPort ?? (secure ? 443 : 8080);
    final key = config?.reverbKey.isNotEmpty == true ? config!.reverbKey : 'local';

    debugPrint('[YAM][WS] connexion Reverb → $scheme://$host:$port (clé $key)');

    final client = PusherChannelsClient.websocket(
      options: PusherChannelsOptions.fromHost(
        scheme: scheme,
        host: host,
        key: key,
        port: port,
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
