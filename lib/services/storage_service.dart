import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact.dart';
import '../models/missed_call.dart';

/// Persistance locale : identité, URL serveur, contacts, historique.
class StorageService {
  static const defaultServerUrl = 'http://192.168.1.80:8000';

  static const _kDeviceId = 'device_id';
  static const _kUserName = 'user_name';
  static const _kServerUrl = 'server_url';
  static const _kContacts = 'contacts_v1';
  static const _kCalls = 'calls_v1';
  static const _kAuthToken = 'auth_token';
  static const _kUserId = 'user_id';
  static const _kUserPhone = 'user_phone';

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

  Future<String> loadServerUrl() async =>
      (await _prefs).getString(_kServerUrl) ?? defaultServerUrl;

  Future<void> saveServerUrl(String url) async =>
      (await _prefs).setString(_kServerUrl, url);

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
