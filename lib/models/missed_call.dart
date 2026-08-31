/// Une entrée d'historique d'appel (manqué/refusé ou terminé).
class CallRecord {
  CallRecord({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.at,
    required this.missed,
  });

  final String id;
  final String peerId;
  final String peerName;
  final DateTime at;

  /// true = manqué/refusé (compte dans le badge), false = appel émis terminé.
  final bool missed;

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerId': peerId,
        'peerName': peerName,
        'at': at.toIso8601String(),
        'missed': missed,
      };

  factory CallRecord.fromJson(Map<String, dynamic> j) => CallRecord(
        id: j['id'] as String,
        peerId: j['peerId'] as String,
        peerName: (j['peerName'] as String?) ?? '',
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
        missed: (j['missed'] as bool?) ?? false,
      );
}
