import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yam_mobile/services/api_client.dart';

/// Tests du mécanisme d'offre différée côté client HTTP.
///
/// `ApiClient.fetchDeferredOffer` récupère l'offre SDP stockée par le serveur
/// (GET /call/{call_id}/offer) quand elle n'a pas été reçue en temps réel.
/// Contrat : payload `{sdp, type}` sur 200, null sur toute autre issue
/// (404/403/410/422, erreur réseau, payload illisible).
void main() {
  group('ApiClient.fetchDeferredOffer', () {
    late ApiClient client;

    ApiClient buildClient(MockClient mock) =>
        ApiClient(() => 'https://api.example.com', client: mock);

    test('retourne le payload {sdp, type} quand le serveur répond 200', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api.example.com/api/v1/call/call-1/offer?device_id=dev-bob',
        );
        return http.Response(
          jsonEncode({
            'ok': true,
            'call_id': 'call-1',
            'type': 'offer',
            'payload': {'sdp': 'v=0\r\no=alice\r\n', 'type': 'offer'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      client = buildClient(mock);

      final result = await client.fetchDeferredOffer(
        callId: 'call-1',
        deviceId: 'dev-bob',
      );

      expect(result, {'sdp': 'v=0\r\no=alice\r\n', 'type': 'offer'});
    });

    test('encode call_id et device_id dans l\'URL', () async {
      final mock = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api.example.com/api/v1/call/call%201/offer?device_id=dev%2Bbob',
        );
        return http.Response(
          jsonEncode({
            'ok': true,
            'payload': {'sdp': 'sdp', 'type': 'offer'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      client = buildClient(mock);

      await client.fetchDeferredOffer(callId: 'call 1', deviceId: 'dev+bob');
    });

    test('retourne null quand le payload est absent de la réponse 200', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'ok': true, 'call_id': 'call-1'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      client = buildClient(mock);

      final result = await client.fetchDeferredOffer(
        callId: 'call-1',
        deviceId: 'dev-bob',
      );

      expect(result, isNull);
    });

    test('retourne null quand le payload n\'est pas un objet JSON', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'ok': true, 'payload': 'pas-un-objet'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      client = buildClient(mock);

      final result = await client.fetchDeferredOffer(
        callId: 'call-1',
        deviceId: 'dev-bob',
      );

      expect(result, isNull);
    });

    test('retourne null sur 404 (offre introuvable)', () async {
      final mock = MockClient(
        (request) async => http.Response(
          jsonEncode({'ok': false, 'error': 'offer_not_found'}),
          404,
          headers: {'content-type': 'application/json'},
        ),
      );
      client = buildClient(mock);

      expect(
        await client.fetchDeferredOffer(callId: 'call-1', deviceId: 'dev-bob'),
        isNull,
      );
    });

    test('retourne null sur 403 (device non destinataire)', () async {
      final mock = MockClient(
        (request) async => http.Response(
          jsonEncode({'ok': false, 'error': 'forbidden_device'}),
          403,
          headers: {'content-type': 'application/json'},
        ),
      );
      client = buildClient(mock);

      expect(
        await client.fetchDeferredOffer(callId: 'call-1', deviceId: 'dev-eve'),
        isNull,
      );
    });

    test('retourne null sur 410 (offre expirée)', () async {
      final mock = MockClient(
        (request) async => http.Response(
          jsonEncode({'ok': false, 'error': 'offer_expired'}),
          410,
          headers: {'content-type': 'application/json'},
        ),
      );
      client = buildClient(mock);

      expect(
        await client.fetchDeferredOffer(callId: 'call-1', deviceId: 'dev-bob'),
        isNull,
      );
    });

    test('retourne null sur 422 (device_id invalide)', () async {
      final mock = MockClient(
        (request) async => http.Response(
          jsonEncode({'message': 'validation', 'errors': {}}),
          422,
          headers: {'content-type': 'application/json'},
        ),
      );
      client = buildClient(mock);

      expect(
        await client.fetchDeferredOffer(callId: 'call-1', deviceId: ''),
        isNull,
      );
    });

    test('retourne null sur erreur réseau (exception)', () async {
      final mock = MockClient(
        (request) async => throw http.ClientException('connexion refusée'),
      );
      client = buildClient(mock);

      expect(
        await client.fetchDeferredOffer(callId: 'call-1', deviceId: 'dev-bob'),
        isNull,
      );
    });

    test('retourne null sur réponse non-JSON', () async {
      final mock = MockClient(
        (request) async => http.Response('<html>erreur</html>', 200),
      );
      client = buildClient(mock);

      expect(
        await client.fetchDeferredOffer(callId: 'call-1', deviceId: 'dev-bob'),
        isNull,
      );
    });
  });

  group('ApiClient.signal — champ call_id', () {
    test('inclut call_id dans le body quand il est fourni (offer)', () async {
      late Map<String, dynamic> sentBody;
      final mock = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'ok': true}), 200,
            headers: {'content-type': 'application/json'});
      });
      final client =
          ApiClient(() => 'https://api.example.com', client: mock);

      await client.signal(
        toDeviceId: 'dev-bob',
        fromDeviceId: 'dev-alice',
        type: 'offer',
        callId: 'call-42',
        payload: {
          'sdp': {'type': 'offer', 'sdp': 'v=0\r\n'},
        },
      );

      expect(sentBody['call_id'], 'call-42');
      expect(sentBody['type'], 'offer');
      expect(sentBody['to_device_id'], 'dev-bob');
    });

    test('omet call_id dans le body quand il est null (candidate)', () async {
      late Map<String, dynamic> sentBody;
      final mock = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'ok': true}), 200,
            headers: {'content-type': 'application/json'});
      });
      final client =
          ApiClient(() => 'https://api.example.com', client: mock);

      await client.signal(
        toDeviceId: 'dev-bob',
        fromDeviceId: 'dev-alice',
        type: 'candidate',
        payload: {'candidate': {'candidate': 'cand'}},
      );

      expect(sentBody.containsKey('call_id'), isFalse);
    });

    test('omet call_id quand il est une chaîne vide', () async {
      late Map<String, dynamic> sentBody;
      final mock = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'ok': true}), 200,
            headers: {'content-type': 'application/json'});
      });
      final client =
          ApiClient(() => 'https://api.example.com', client: mock);

      await client.signal(
        toDeviceId: 'dev-bob',
        fromDeviceId: 'dev-alice',
        type: 'bye',
        callId: '',
        payload: {},
      );

      expect(sentBody.containsKey('call_id'), isFalse);
    });
  });
}