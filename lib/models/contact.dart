/// Un contact enregistré localement (nom + identifiant utilisateur).
///
/// Le backend route le premier signal vers tous les appareils de l'utilisateur
/// (`to_user_id`). Le device précis n'est connu qu'après la réponse WebRTC.
class Contact {
  Contact({required this.id, required this.name, required this.userId, this.phoneNumber});

  final String id;
  String name;
  String userId;
  String? phoneNumber;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'userId': userId,
        if (phoneNumber != null) 'phoneNumber': phoneNumber,
      };

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        // Compatibilité avec les contacts historiques : ils doivent être
        // recherchés de nouveau avant d'être appelés, car device_id n'est plus
        // une cible d'appel valide.
        userId: (j['userId'] ?? '') as String,
        phoneNumber: j['phoneNumber'] as String?,
      );

  /// Initiale affichée dans les avatars.
  String get initial =>
      name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
}
