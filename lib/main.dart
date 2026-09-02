import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'screens/auth_screen.dart';
import 'state/app_state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  // L'init réseau ne bloque pas l'affichage : l'UI montre l'état de connexion.
  unawaited(app.init());
  runApp(YamApp(app: app));
}

class YamApp extends StatelessWidget {
  const YamApp({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: YamColors.pageBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: YamColors.accent,
          surface: YamColors.surface,
          error: YamColors.danger,
        ),
      ),
      home: ListenableBuilder(
        listenable: app,
        builder: (context, _) => app.isAuthenticated
            ? HomeShell(app: app)
            : AuthScreen(app: app),
      ),
    );
  }
}
