import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yam_mobile/services/storage_service.dart';

/// Tests de la persistance de l'URL serveur et de sa migration.
///
/// L'ancienne URL LAN par défaut (`http://192.168.1.80:8000`) doit être
/// remplacée par la production (`https://yam.mdkrlabs.dev`), y compris dans
/// ses variantes (slash final, espaces). Les URLs personnalisées saisies par
/// l'utilisateur doivent être conservées telles quelles.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StorageService.loadServerUrl', () {
    test('retourne la production quand rien n’est stocké', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      expect(await storage.loadServerUrl(), StorageService.defaultServerUrl);
    });

    test('retourne la production quand la valeur stockée est vide', () async {
      SharedPreferences.setMockInitialValues({'server_url': ''});
      final storage = StorageService();
      expect(await storage.loadServerUrl(), StorageService.defaultServerUrl);
    });

    test('migre l’ancienne URL LAN par défaut', () async {
      SharedPreferences.setMockInitialValues(
          {'server_url': 'http://192.168.1.80:8000'});
      final storage = StorageService();
      expect(await storage.loadServerUrl(), StorageService.defaultServerUrl);
    });

    test('migre l’ancienne URL LAN avec slash final', () async {
      SharedPreferences.setMockInitialValues(
          {'server_url': 'http://192.168.1.80:8000/'});
      final storage = StorageService();
      expect(await storage.loadServerUrl(), StorageService.defaultServerUrl);
    });

    test('migre l’ancienne URL LAN avec espaces autour', () async {
      SharedPreferences.setMockInitialValues(
          {'server_url': '  http://192.168.1.80:8000  '});
      final storage = StorageService();
      expect(await storage.loadServerUrl(), StorageService.defaultServerUrl);
    });

    test('conserve une URL personnalisée', () async {
      SharedPreferences.setMockInitialValues(
          {'server_url': 'https://mon-serveur.example.com'});
      final storage = StorageService();
      expect(await storage.loadServerUrl(), 'https://mon-serveur.example.com');
    });

    test('conserve une URL personnalisée en la trimant', () async {
      SharedPreferences.setMockInitialValues(
          {'server_url': '  https://mon-serveur.example.com/  '});
      final storage = StorageService();
      expect(await storage.loadServerUrl(), 'https://mon-serveur.example.com/');
    });
  });

  group('StorageService.saveServerUrl', () {
    test('sauvegarde l’URL en la trimant', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.saveServerUrl('  https://yam.mdkrlabs.dev  ');
      expect(await storage.loadServerUrl(), 'https://yam.mdkrlabs.dev');
    });
  });
}