/// Un contact enregistré localement (nom + device id).
class Contact {
  Contact({required this.id, required this.name, required this.deviceId});

  final String id;
  String name;
  String deviceId;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'deviceId': deviceId};

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        deviceId: j['deviceId'] as String,
      );

  /// Initiale affichée dans les avatars.
  String get initial =>
      name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
}
