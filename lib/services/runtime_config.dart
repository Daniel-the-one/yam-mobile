/// Configuration runtime chargée depuis `GET /api/v1/config`.
///
/// Le backend expose les valeurs Reverb (host/port/scheme/clé) et TURN
/// sans qu'elles soient codées en dur dans le client. Cela permet à l'app
/// de fonctionner en LAN, en tunnel HTTPS et en production sans rebuild.
class RuntimeConfig {
  const RuntimeConfig({
    required this.reverbKey,
    required this.reverbHost,
    required this.reverbPort,
    required this.reverbScheme,
    required this.turnUrl,
    required this.turnUsername,
    required this.turnCredential,
    this.customIceServers,
  });

  final String reverbKey;
  final String reverbHost;
  final int reverbPort;
  final String reverbScheme;
  final String turnUrl;
  final String turnUsername;
  final String turnCredential;

  /// Reconstruit la config à partir de la réponse JSON de `/api/v1/config`.
  /// Retourne null si le payload est illisible (on garde alors les valeurs
  /// par défaut locales).
  factory RuntimeConfig.fromJson(Map<String, dynamic> json) {
    final reverb = (json['reverb'] as Map?)?.cast<String, dynamic>() ?? const {};
    final turn = (json['turn'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rawIce = json['ice_servers'];
    List<Map<String, dynamic>>? parsedIce;
    if (rawIce is List) {
      parsedIce = rawIce.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    }
    return RuntimeConfig(
      reverbKey: (reverb['app_key'] as String?) ?? 'local',
      reverbHost: (reverb['host'] as String?) ?? '',
      reverbPort: (reverb['port'] as num?)?.toInt() ?? 8080,
      reverbScheme: (reverb['scheme'] as String?) ?? 'ws',
      turnUrl: (turn['url'] as String?) ?? '',
      turnUsername: (turn['username'] as String?) ?? '',
      turnCredential: (turn['credential'] as String?) ?? '',
      customIceServers: parsedIce,
    );
  }

  final List<Map<String, dynamic>>? customIceServers;

  /// Liste des serveurs ICE à passer à la PeerConnection.
  /// STUN en secours + serveurs TURN pour traverser les NATs (4G / multi-réseaux).
  List<Map<String, dynamic>> get iceServers {
    if (customIceServers != null && customIceServers!.isNotEmpty) {
      return customIceServers!;
    }
    final servers = <Map<String, dynamic>>[
      {'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302', 'stun:stun2.l.google.com:19302']},
      {'urls': ['stun:stun.cloudflare.com:3478']},
    ];
    if (turnUrl.isNotEmpty) {
      final urls = turnUrl.contains(',')
          ? turnUrl.split(',').map((u) => u.trim()).where((u) => u.isNotEmpty).toList()
          : [turnUrl];
      for (final u in urls) {
        final server = <String, dynamic>{'urls': u};
        if (turnUsername.isNotEmpty) {
          server['username'] = turnUsername;
          server['credential'] = turnCredential;
        }
        servers.add(server);
      }
    }
    return servers;
  }
}
