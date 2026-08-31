import 'package:flutter/material.dart';

/// Jetons de design — ADN visuel de Yam (repris du client web).
class YamColors {
  static const pageBg = Color(0xFFEEF0F3);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFE5E5E5);
  static const text = Color(0xFF171717);
  static const muted = Color(0xFF8A8A8A);
  static const accent = Color(0xFF2563EB);
  static const accentSoft = Color(0xFFEFF4FE);
  static const danger = Color(0xFFB91C1C);
  static const accept = Color(0xFF16A34A);

  // Écrans d'appel sombres (façon Meet).
  static const callCardTop = Color(0xFF2A2A3A);
  static const callCardBottom = Color(0xFF16161F);
  static const avatarBg = Color(0xFF3A3A4A);
}

const kFieldRadius = BorderRadius.all(Radius.circular(8));
const kShellRadius = BorderRadius.all(Radius.circular(16));
const kCardRadius = BorderRadius.all(Radius.circular(20));

/// Style mono pour device IDs, timers et métadonnées techniques.
TextStyle mono({double size = 13, Color color = YamColors.muted}) =>
    TextStyle(fontFamily: 'monospace', fontSize: size, color: color);
