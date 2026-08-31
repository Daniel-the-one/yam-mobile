import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/contact.dart';
import '../models/missed_call.dart';
import '../services/api_client.dart';
import '../services/call_service.dart';
import '../services/push_service.dart';
import '../services/runtime_config.dart';
import '../services/signaling_service.dart';
import '../services/storage_service.dart';

/// État global de l'application : identité, connexion, contacts, historique.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final storage = StorageService();
  late final ApiClient api = ApiClient(() => serverUrl);
  final signaling = SignalingService();
  late final CallService call = CallService(api);
  final push = PushService();

  String serverUrl = StorageService.defaultServerUrl;
  String deviceId = '';
  String userName = '';
  ConnStatus status = ConnStatus.disconnected;
  RuntimeConfig? runtimeConfig;
  List<Contact> contacts = [];
  List<CallRecord> calls = [];
  Timer? _autoReconnectTimer;
  bool _isReconnecting = false;

  int get missedCount => calls.where((c) => c.missed).length;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      await Permission.notification.request();
    } catch (_) {}
    deviceId = await storage.ensureDeviceId();
    userName = await storage.loadUserName();
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

    // Notifications push (FCM) pour réveiller l'appareil hors application.
    // Sans config Firebase, ça échoue silencieusement (le WebSocket reste
    // le canal principal).
    unawaited(push.init(
      serverUrl: serverUrl,
      deviceId: deviceId,
      userName: userName,
      onIncomingCall: call.handleIncomingCall,
      // « Décrocher » sur l'écran CallKit natif → accepte directement l'appel
      // (au lieu de re-sonner dans l'app et d'exiger un second tap).
      onAcceptCall: call.accept,
    ));

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

    await refreshRuntimeConfig();
    await reconnect();

    // Reconnexion automatique périodique si l'appareil est déconnecté
    // (ex: changement de Wi-Fi, bascule 4G, perte temporaire de signal).
    _autoReconnectTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (status == ConnStatus.disconnected && !_isReconnecting && call.phase == CallPhase.idle) {
        debugPrint('[YAM][AUTO-RECONNECT] Tentative de reconnexion au serveur...');
        reconnect();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[YAM][LIFECYCLE] App au premier plan → vérification connexion');
      if (status == ConnStatus.disconnected && call.phase == CallPhase.idle) {
        reconnect();
      }
    }
  }

  /// Charge la config runtime (Reverb + TURN) depuis le backend et la
  /// partage avec la signalisation et le service d'appel.
  Future<void> refreshRuntimeConfig() async {
    final cfg = await api.fetchConfig();
    if (cfg != null) {
      runtimeConfig = cfg;
      call.config = cfg;
      debugPrint('[YAM][CONFIG] TURN=${cfg.turnUrl.isNotEmpty ? "oui" : "non"} '
          'Reverb=${cfg.reverbScheme}://${cfg.reverbHost}:${cfg.reverbPort}');
    }
  }

  Future<void> reconnect() async {
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

  // ─────────────────────────── Contacts ────────────────────────────────

  Future<void> addContact(String name, String devId) async {
    final n = name.trim();
    final d = devId.trim();
    if (n.isEmpty || d.isEmpty) return;
    contacts.add(Contact(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: n,
      deviceId: d,
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
