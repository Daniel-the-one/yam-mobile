import 'package:flutter_test/flutter_test.dart';
import 'package:yam_mobile/models/contact.dart';
import 'package:yam_mobile/models/missed_call.dart';
import 'package:yam_mobile/services/call_service.dart';
import 'package:yam_mobile/services/runtime_config.dart';

void main() {
  group('WebRTC SDP Normalisation', () {
    test('ajoute un retour chariot final si manquant', () {
      expect(sdpNormalise('v=0\r\no=- 123 2 IN IP4 127.0.0.1'), 'v=0\r\no=- 123 2 IN IP4 127.0.0.1\r\n');
    });

    test('laisse le SDP intact si le retour chariot est déjà présent', () {
      expect(sdpNormalise('v=0\r\no=- 123 2 IN IP4 127.0.0.1\r\n'), 'v=0\r\no=- 123 2 IN IP4 127.0.0.1\r\n');
    });
  });

  group('Contact Model', () {
    test('sérialise et désérialise un contact correctement', () {
      final contact = Contact(
        id: '123',
        name: 'Damien',
        userId: 'user-abc12345',
      );
      final json = contact.toJson();
      final recovered = Contact.fromJson(json);

      expect(recovered.id, contact.id);
      expect(recovered.name, contact.name);
      expect(recovered.userId, contact.userId);
    });
  });

  group('CallRecord Model', () {
    test('sérialise et désérialise un enregistrement d appel', () {
      final now = DateTime.now();
      final record = CallRecord(
        id: '999',
        peerId: 'device-target01',
        peerName: 'Bureau',
        at: now,
        missed: true,
      );
      final json = record.toJson();
      final recovered = CallRecord.fromJson(json);

      expect(recovered.id, record.id);
      expect(recovered.peerId, record.peerId);
      expect(recovered.peerName, record.peerName);
      expect(recovered.missed, isTrue);
    });
  });

  group('RuntimeConfig Parser', () {
    test('parse correctement la réponse du backend Laravel /api/v1/config', () {
      final json = {
        'pusher': {
          'app_key': '3db783706efc3d236b8a',
          'cluster': 'eu',
        },
        'turn': {
          'url': 'turn:turn.example.com:3478',
          'username': 'user',
          'credential': 'secret',
        },
      };

      final config = RuntimeConfig.fromJson(json);
      expect(config.pusherKey, '3db783706efc3d236b8a');
      expect(config.pusherCluster, 'eu');
      expect(config.turnUrl, 'turn:turn.example.com:3478');
      expect(config.iceServers.length, 3);
      expect(config.iceServers[0]['urls'], [
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
        'stun:stun2.l.google.com:19302',
      ]);
      expect(config.iceServers[1]['urls'], ['stun:stun.cloudflare.com:3478']);
      expect(config.iceServers[2]['urls'], 'turn:turn.example.com:3478');
    });
  });
}
