import 'package:flutter/services.dart';

/// Accès au MethodChannel natif pour la gestion de l'optimisation batterie.
///
/// Les OEM (TECNO/Infinix/Xiaomi/Huawei…) tuent agressivement les apps en
/// arrière-plan, ce qui retarde ou bloque la délivrance des notifications
/// FCM d'appel entrant. Demander l'exemption batterie est le moyen le plus
/// fiable de garantir que les appels arrivent quand l'app est fermée.
class BatteryOptimizationService {
  static const _channel = MethodChannel('yam/battery_optimization');

  /// Vrai si l'app est déjà exemptée de l'optimisation batterie.
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return ok ?? false;
    } catch (_) {
      return false; // plateforme non Android ou channel indisponible
    }
  }

  /// Ouvre le dialog système « Autoriser Yam à ignorer l'optimisation de la
  /// batterie ? ».
  Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } catch (_) {
      // Ignoré : l'utilisateur peut toujours le faire manuellement.
    }
  }

  /// Ouvre les paramètres batterie (fallback si le dialog n'est pas dispo).
  Future<void> openBatterySettings() async {
    try {
      await _channel.invokeMethod<void>('openBatterySettings');
    } catch (_) {}
  }
}