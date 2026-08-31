import 'dart:convert';

import 'package:http/http.dart' as http;

import 'runtime_config.dart';

/// Client REST de l'API Yam. Routes : config, ring, signal.
class ApiClient {
  ApiClient(this.baseUrlProvider, {http.Client? client})
      : _client = client ?? http.Client();

  /// Fournit l'URL courante (modifiable dans les réglages de l'app).
  final String Function() baseUrlProvider;

  /// Client HTTP utilisé pour les requêtes. Injectable pour les tests
  /// (MockClient de package:http/testing) ; par défaut un vrai client.
  final http.Client _client;

  Uri _uri(String path) {
    final base = baseUrlProvider().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  /// Récupère la configuration runtime (Reverb + TURN) depuis le backend.
  /// Retourne null si l'endpoint est injoignable ou illisible (l'app garde
  /// alors ses valeurs par défaut locales).
  Future<RuntimeConfig?> fetchConfig() async {
    try {
      final res = await _client
          .get(_uri('/api/v1/config'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body);
      if (json is! Map<String, dynamic>) return null;
      return RuntimeConfig.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await _client
        .post(
          _uri(path),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('API $path → HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Fait sonner l'appareil cible. Retourne le call_id si fourni.
  ///
  /// [type] : `'audio'` (défaut) ou `'video'` — détermine le type d'appel.
  Future<String?> ring({
    required String toDeviceId,
    required String fromDeviceId,
    required String fromUsername,
    String type = 'audio',
  }) async {
    final data = await _post('/api/v1/call/ring', {
      'to_device_id': toDeviceId,
      'from_device_id': fromDeviceId,
      'from_username': fromUsername,
      'type': type,
    });
    return data['call_id'] as String?;
  }

  /// Envoie un signal WebRTC (offer / answer / candidate / bye).
  ///
  /// [callId] : identifiant de l'appel, requis pour le stockage différé de
  /// l'offre côté serveur (type=offer) et l'invalidation au raccrochage
  /// (type=bye).
  Future<void> signal({
    required String toDeviceId,
    required String fromDeviceId,
    required String type,
    required Map<String, dynamic> payload,
    String? callId,
  }) async {
    await _post('/api/v1/call/signal', {
      'to_device_id': toDeviceId,
      'from_device_id': fromDeviceId,
      'type': type,
      'payload': payload,
      if (callId != null && callId.isNotEmpty) 'call_id': callId,
    });
  }

  /// Récupère l'offre SDP différée stockée par le serveur pour un appel.
  ///
  /// Retourne le payload de l'offre (`{sdp, type}`) ou null si l'offre est
  /// introuvable, expirée ou interdite (l'appelant a raccroché, timeout...).
  Future<Map<String, dynamic>?> fetchDeferredOffer({
    required String callId,
    required String deviceId,
  }) async {
    try {
      final uri = _uri(
          '/api/v1/call/${Uri.encodeComponent(callId)}/offer'
          '?device_id=${Uri.encodeComponent(deviceId)}');
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body);
      if (json is! Map<String, dynamic>) return null;
      return (json['payload'] as Map?)?.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}
