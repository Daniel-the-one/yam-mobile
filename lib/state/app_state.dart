import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/contact.dart';
import '../models/missed_call.dart';
import '../services/api_client.dart';
import '../services/battery_optimization_service.dart';
import '../services/call_service.dart';
import '../services/push_service.dart';
import '../services/runtime_config.dart';
import '../services/signaling_service.dart';
import '../services/storage_service.dart';

/// État global de l'application : identité, connexion, contacts, historique.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final storage = StorageService();
  late final ApiClient api = ApiClient(
    () => serverUrl,
    tokenProvider: () => authToken,
  );
  final signaling = SignalingService();
  late final CallService call = CallService(api);
  final push = PushService();
  final batteryOptimization = BatteryOptimizationService();

  String serverUrl = StorageService.defaultServerUrl;
  String deviceId = '';
  String userName = '';
  String userId = '';
  String authToken = '';
  ConnStatus status = ConnStatus.disconnected;
  RuntimeConfig? runtimeConfig;
  List<Contact> contacts = [];
  List<CallRecord> calls = [];
  Timer? _autoReconnectTimer;
  bool _isReconnecting = false;

  int get missedCount => calls.where((c) => c.missed).length;
  bool get isAuthenticated => authToken.isNotEmpty && userId.isNotEmpty;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      await Permission.notification.request();
    } catch (_) {}
    deviceId = await storage.ensureDeviceId();
    userName = await storage.loadUserName();
    userId = await storage.loadUserId();
    authToken = await storage.loadAuthToken();
    if (userName.isEmpty) {
      final suffix = deviceId.length > 4 ? deviceId.substring(deviceId.length - 4) : deviceId;
      userName = 'Appareil $suffix';
      await storage.saveUserName(userName);
    }
    serverUrl = await storage.loadServerUrl();
    contacts = await storage.loadContacts();
    calls = await storage.loadCalls();
    call.myDeviceId = deviceId;
    call.myName = userName;

    signaling.onStatus = (s) {
      status = s;
      notifyListeners();
    };
    signaling.onIncomingCall = call.handleIncomingCall;
    signaling.onSignal = call.handleSignal;
    call.onCallEnded = (peerId, peerName, missed) {
      logCall(peerId: peerId, peerName: peerName, missed: missed);
      // Termine l'écran d'appel natif (CallKit) si affiché.
      if (call.currentCallId != null) {
        unawaited(push.endCall(call.currentCallId!));
      }
    };
    call.addListener(notifyListeners);

    if (isAuthenticated) await _startAuthenticatedSession();

    // Reconnexion automatique périodique si l'appareil est déconnecté
    // (ex: changement de Wi-Fi, bascule 4G, perte temporaire de signal).
    _autoReconnectTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (isAuthenticated && status == ConnStatus.disconnected && !_isReconnecting && call.phase == CallPhase.idle) {
        debugPrint('[YAM][AUTO-RECONNECT] Tentative de reconnexion au serveur...');
        reconnect();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[YAM][LIFECYCLE] App au premier plan → vérification connexion');
      if (isAuthenticated && status == ConnStatus.disconnected && call.phase == CallPhase.idle) {
        reconnect();
      }
    }
  }

  /// Charge la config runtime (Pusher + TURN) depuis le backend et la
  /// partage avec la signalisation et le service d'appel.
  Future<void> refreshRuntimeConfig() async {
    final cfg = await api.fetchConfig();
    if (cfg != null) {
      runtimeConfig = cfg;
      call.config = cfg;
      debugPrint('[YAM][CONFIG] TURN=${cfg.turnUrl.isNotEmpty ? "oui" : "non"} '
          'Pusher=cluster ${cfg.pusherCluster} (clé ${cfg.pusherKey})');
    }
  }

  Future<void> reconnect() async {
    if (!isAuthenticated) return;
    if (_isReconnecting) return;
    _isReconnecting = true;
    status = ConnStatus.connecting;
    notifyListeners();
    try {
      await refreshRuntimeConfig();
      await signaling.connect(
        serverUrl: serverUrl,
        deviceId: deviceId,
        config: runtimeConfig,
      );
    } catch (e) {
      debugPrint('[YAM][RECONNECT] Erreur de reconnexion : $e');
    } finally {
      _isReconnecting = false;
    }
  }

  Future<void> updateServerUrl(String url) async {
    serverUrl = url.trim();
    await storage.saveServerUrl(serverUrl);
    notifyListeners();
    // Ré-enregistre le device FCM auprès du nouveau serveur : sans cela, les
    // appels entrants en arrière-plan/app fermée continueraient de pointer
    // vers l'ancien serveur jusqu'au redémarrage de l'app.
    await push.updateServerUrl(serverUrl);
    await reconnect();
  }

  Future<void> updateUserName(String name) async {
    userName = name.trim();
    if (userName.isEmpty) {
      userName = 'Appareil ${deviceId.length > 4 ? deviceId.substring(deviceId.length - 4) : deviceId}';
    }
    call.myName = userName;
    await storage.saveUserName(userName);
    notifyListeners();
  }

  Future<void> login({
    required String phoneNumber,
    required String password,
  }) async {
    final result = await api.login(
      phoneNumber: phoneNumber.trim(),
      password: password,
      deviceId: deviceId,
      platform: 'android',
      label: userName,
    );
    await _storeAuthenticatedSession(result);
  }

  Future<void> register({
    required String name,
    required String phoneNumber,
    required String password,
    String? username,
  }) async {
    final result = await api.register(
      name: name.trim(),
      phoneNumber: phoneNumber.trim(),
      password: password,
      deviceId: deviceId,
      platform: 'android',
      username: username?.trim(),
    );
    await _storeAuthenticatedSession(result);
  }

  Future<void> logout() async {
    try {
      await api.logout();
    } catch (_) {
      // Le nettoyage local reste nécessaire même si le serveur est injoignable.
    }
    await signaling.disconnect();
    await storage.clearSession();
    authToken = '';
    userId = '';
    status = ConnStatus.disconnected;
    notifyListeners();
  }

  Future<void> _storeAuthenticatedSession(Map<String, dynamic> response) async {
    final data = (response['data'] as Map?)?.cast<String, dynamic>() ?? response;
    final user = (data['user'] as Map?)?.cast<String, dynamic>() ?? const {};
    final token = data['token']?.toString() ?? '';
    final id = user['id']?.toString() ?? '';
    if (token.isEmpty || id.isEmpty) throw Exception('Réponse d’authentification invalide.');
    authToken = token;
    userId = id;
    userName = user['name']?.toString() ?? userName;
    call.myName = userName;
    await storage.saveSession(
      token: token,
      userId: id,
      userName: userName,
      phoneNumber: user['phone_number']?.toString(),
    );
    await _startAuthenticatedSession();
    notifyListeners();
  }

  Future<void> _startAuthenticatedSession() async {
    unawaited(push.init(
      serverUrl: serverUrl,
      deviceId: deviceId,
      userName: userName,
      authToken: authToken,
      onIncomingCall: call.handleIncomingCall,
      onAcceptCall: call.accept,
    ));
    await refreshRuntimeConfig();
    await reconnect();
    // Les OEM (TECNO/Infinix/Xiaomi) tuent les apps en arrière-plan : sans
    // exemption batterie, les notifications FCM d'appel entrant peuvent être
    // retardées ou bloquées. On demande l'exemption une fois par session.
    unawaited(_requestBatteryExemptionIfNeeded());
  }

  /// Demande l'exemption d'optimisation batterie si l'app n'est pas déjà
  /// exemptée et que l'utilisateur ne l'a pas déjà refusée. Non bloquant :
  /// en cas d'échec, l'utilisateur peut toujours l'activer manuellement.
  Future<void> _requestBatteryExemptionIfNeeded() async {
    try {
      // Ne pas re-proposer si l'utilisateur a déjà fermé/refusé le dialog.
      if (await storage.loadBatteryExemptionDismissed()) return;
      final exempted = await batteryOptimization.isIgnoringBatteryOptimizations();
      if (!exempted) {
        debugPrint('[YAM][BATTERY] App non exemptée → demande d\'exemption');
        await batteryOptimization.requestIgnoreBatteryOptimizations();
        // On considère la demande faite (acceptée ou non) : on ne la
        // re-propose pas à chaque session.
        await storage.saveBatteryExemptionDismissed(true);
      }
    } catch (e) {
      debugPrint('[YAM][BATTERY] Demande d\'exemption impossible : $e');
    }
  }

  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    if (!isAuthenticated || query.trim().isEmpty) return [];
    return api.searchUsers(query.trim());
  }

  // ─────────────────────────── Contacts ────────────────────────────────

  Future<void> addContact(String name, String targetUserId, {String? phoneNumber}) async {
    final n = name.trim();
    final id = targetUserId.trim();
    if (n.isEmpty || id.isEmpty) return;
    contacts.add(Contact(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: n,
      userId: id,
      phoneNumber: phoneNumber,
    ));
    await storage.saveContacts(contacts);
    notifyListeners();
  }

  Future<void> removeContact(Contact c) async {
    contacts.removeWhere((x) => x.id == c.id);
    await storage.saveContacts(contacts);
    notifyListeners();
  }

  // ────────────────────────── Historique ───────────────────────────────

  Future<void> logCall({
    required String peerId,
    required String peerName,
    required bool missed,
  }) async {
    calls.insert(
      0,
      CallRecord(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        peerId: peerId,
        peerName: peerName,
        at: DateTime.now(),
        missed: missed,
      ),
    );
    if (calls.length > 50) calls.removeRange(50, calls.length);
    await storage.saveCalls(calls);
    notifyListeners();
  }

  Future<void> removeCall(CallRecord r) async {
    calls.removeWhere((x) => x.id == r.id);
    await storage.saveCalls(calls);
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoReconnectTimer?.cancel();
    super.dispose();
  }
}
