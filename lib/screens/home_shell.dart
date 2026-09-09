import 'package:flutter/material.dart';

import '../services/call_service.dart';
import '../services/signaling_service.dart';
import '../services/storage_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'calls_screen.dart';
import 'contacts_screen.dart';
import 'home_screen.dart';
import 'in_call_screen.dart';
import 'incoming_call_screen.dart';

/// Coquille principale : en-tête + 3 onglets + overlays d'appel plein écran.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.app});

  final AppState app;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final call = app.call;
        final showIncoming = call.phase == CallPhase.incoming;
        final showActive =
            call.phase == CallPhase.calling || call.phase == CallPhase.inCall;
        return Scaffold(
          backgroundColor: YamColors.pageBg,
          body: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                Column(
                  children: [
                    _Header(app: app),
                    Expanded(
                      child: IndexedStack(
                        index: _tab,
                        children: [
                          HomeScreen(app: app),
                          ContactsScreen(app: app),
                          CallsScreen(app: app),
                        ],
                      ),
                    ),
                  ],
                ),
                if (showIncoming)
                  Positioned.fill(
                    key: const ValueKey('incoming_call_overlay'),
                    child: IncomingCallScreen(
                      key: const ValueKey('incoming_call_screen'),
                      app: app,
                      onAccept: () => call.accept(),
                      onRefuse: () => call.refuse(),
                    ),
                  ),
                if (showActive)
                  Positioned.fill(
                    key: const ValueKey('active_call_overlay'),
                    child: InCallScreen(
                      key: const ValueKey('in_call_screen'),
                      app: app,
                    ),
                  ),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            height: 66,
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Accueil',
              ),
              const NavigationDestination(
                icon: Icon(Icons.people_alt_outlined),
                selectedIcon: Icon(Icons.people_alt),
                label: 'Contacts',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: app.missedCount > 0,
                  backgroundColor: YamColors.danger,
                  label: Text('${app.missedCount}'),
                  child: const Icon(Icons.history),
                ),
                selectedIcon: const Icon(Icons.history),
                label: 'Appels',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// En-tête discret : nom + pastille de connexion + réglages serveur.
class _Header extends StatelessWidget {
  const _Header({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final (label, dotColor) = switch (app.status) {
      ConnStatus.connected => ('Connecté', YamColors.accent),
      ConnStatus.connecting => ('Connexion…', YamColors.muted),
      ConnStatus.disconnected => ('Déconnecté', YamColors.danger),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
      child: Row(
        children: [
          const Text('Yam',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: YamColors.text)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: YamColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: YamColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(label,
                    style:
                        const TextStyle(fontSize: 12, color: YamColors.muted)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Adresse du serveur',
            onPressed: () => _editServer(context).catchError((Object e) {
              debugPrint('[YAM][SERVER] Erreur changement d’adresse : $e');
            }),
            icon: const Icon(Icons.settings_outlined, color: YamColors.muted),
          ),
        ],
      ),
    );
  }

  Future<void> _editServer(BuildContext context) async {
    final newUrl = await showDialog<String>(
      context: context,
      builder: (_) => _ServerUrlDialog(initialUrl: app.serverUrl),
    );
    if (newUrl != null && newUrl.trim().isNotEmpty) {
      await app.updateServerUrl(newUrl.trim());
    }
  }
}

/// Dialog de saisie de l'adresse du serveur.
///
/// StatefulWidget dédié : le [TextEditingController] vit dans le State et est
/// disposé quand le widget est réellement démonté (après l'animation de
/// fermeture du dialog). Disposer le controller dans le parent juste après
/// `showDialog` déclenche l'assertion `_dependents.isEmpty` (le TextField
/// écoute encore le controller pendant la transition de sortie).
class _ServerUrlDialog extends StatefulWidget {
  const _ServerUrlDialog({required this.initialUrl});

  final String initialUrl;

  @override
  State<_ServerUrlDialog> createState() => _ServerUrlDialogState();
}

class _ServerUrlDialogState extends State<_ServerUrlDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialUrl);
    _ctrl.addListener(_onChanged);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  /// Valide une URL de serveur : schéma http/https et hôte non vide.
  bool _isValidUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final text = _ctrl.text.trim();
    final valid = _isValidUrl(text);
    return AlertDialog(
      title: const Text('Adresse du serveur'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          hintText: StorageService.defaultServerUrl,
          // N'affiche l'erreur que si l'utilisateur a saisi quelque chose
          // d'invalide (un champ vide au premier lancement n'est pas une
          // erreur, mais « Enregistrer » reste désactivé).
          errorText: text.isNotEmpty && !valid
              ? 'URL invalide (ex. https://yam.mdkrlabs.dev)'
              : null,
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler')),
        FilledButton(
            onPressed:
                valid ? () => Navigator.pop(context, text) : null,
            child: const Text('Enregistrer')),
      ],
    );
  }
}
