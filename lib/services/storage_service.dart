import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact.dart';
import '../models/missed_call.dart';

/// Persistance locale : identité, URL serveur, contacts, historique.
class StorageService {
  /// URL du serveur de production (web + API + config servis depuis le même
  /// hôte). L'ancienne URL LAN (`http://192.168.1.80:8000`) est migrée
  /// automatiquement vers celle-ci dans [loadServerUrl].
  static const defaultServerUrl = 'https://yam.mdkrlabs.dev';

  /// Ancienne URL par défaut (développement LAN) — utilisée uniquement pour
  /// la migration des appareils déjà configurés.
  static const _legacyDefaultServerUrl = 'http://192.168.1.80:8000';

  static const _kDeviceId = 'device_id';
  static const _kUserName = 'user_name';
  static const _kServerUrl = 'server_url';
  static const _kContacts = 'contacts_v1';
  static const _kCalls = 'calls_v1';
  static const _kAuthToken = 'auth_token';
  static const _kUserId = 'user_id';
  static const _kUserPhone = 'user_phone';
  static const _kBatteryExemptionDismissed = 'battery_exemption_dismissed';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// Génère et persiste un identifiant unique au premier lancement :
  /// `device-` + 8 caractères aléatoires [a-z0-9].
  Future<String> ensureDeviceId() async {
    final p = await _prefs;
    final existing = p.getString(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    final suffix =
        List.generate(8, (_) => chars[rnd.nextInt(chars.length)]).join();
    final id = 'device-$suffix';
    await p.setString(_kDeviceId, id);
    return id;
  }

  Future<String> loadUserName() async =>
      (await _prefs).getString(_kUserName) ?? '';

  Future<void> saveUserName(String name) async =>
      (await _prefs).setString(_kUserName, name);

  Future<String> loadAuthToken() async =>
      (await _prefs).getString(_kAuthToken) ?? '';

  Future<String> loadUserId() async =>
      (await _prefs).getString(_kUserId) ?? '';

  Future<void> saveSession({
    required String token,
    required String userId,
    required String userName,
    String? phoneNumber,
  }) async {
    final p = await _prefs;
    await p.setString(_kAuthToken, token);
    await p.setString(_kUserId, userId);
    await p.setString(_kUserName, userName);
    if (phoneNumber != null) await p.setString(_kUserPhone, phoneNumber);
  }

  Future<void> clearSession() async {
    final p = await _prefs;
    await p.remove(_kAuthToken);
    await p.remove(_kUserId);
    await p.remove(_kUserPhone);
  }

  /// Vrai si l'utilisateur a déjà refusé (ou fermé) la demande d'exemption
  /// batterie : on ne la re-propose pas à chaque session.
  Future<bool> loadBatteryExemptionDismissed() async =>
      (await _prefs).getBool(_kBatteryExemptionDismissed) ?? false;

  Future<void> saveBatteryExemptionDismissed(bool dismissed) async =>
      (await _prefs).setBool(_kBatteryExemptionDismissed, dismissed);

  Future<String> loadServerUrl() async {
    final p = await _prefs;
    final stored = p.getString(_kServerUrl);
    // Migration : l'ancienne URL LAN par défaut est remplacée par la
    // production. Les URLs personnalisées saisies par l'utilisateur sont
    // conservées telles quelles. La comparaison est insensible aux variantes
    // de l'ancienne URL (slash final, espaces) pour ne laisser aucun appareil
    // pointé sur le LAN.
    final normalized = stored?.trim().replaceAll(RegExp(r'/+$'), '');
    if (normalized == null ||
        normalized.isEmpty ||
        normalized == _legacyDefaultServerUrl) {
      return defaultServerUrl;
    }
    return stored!.trim();
  }

  Future<void> saveServerUrl(String url) async =>
      (await _prefs).setString(_kServerUrl, url.trim());

  Future<List<Contact>> loadContacts() async {
    final raw = (await _prefs).getString(_kContacts);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(Contact.fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveContacts(List<Contact> items) async {
    final p = await _prefs;
    await p.setString(
        _kContacts, jsonEncode(items.map((c) => c.toJson()).toList()));
  }

  Future<List<CallRecord>> loadCalls() async {
    final raw = (await _prefs).getString(_kCalls);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(CallRecord.fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveCalls(List<CallRecord> items) async {
    final p = await _prefs;
    await p.setString(_kCalls, jsonEncode(items.map((c) => c.toJson()).toList()));
  }
}
