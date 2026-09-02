import 'package:flutter/material.dart';

import '../models/contact.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Contacts : formulaire d'ajout + liste avec appeler / supprimer.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, required this.app});

  final AppState app;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _queryCtrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() => _searching = true);
    try {
      _results = await widget.app.searchUsers(query);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
    FocusScope.of(context).unfocus();
  }

  InputDecoration _deco(String hint, {bool monoStyle = false}) => InputDecoration(
        hintText: hint,
        hintStyle: monoStyle ? mono(size: 14) : null,
        filled: true,
        fillColor: YamColors.surface,
        border: OutlineInputBorder(borderRadius: kFieldRadius),
        enabledBorder: OutlineInputBorder(
          borderRadius: kFieldRadius,
          borderSide: const BorderSide(color: YamColors.border),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _queryCtrl,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: _deco('Téléphone, nom ou nom d’utilisateur'),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 44,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: YamColors.text,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: kFieldRadius),
            ),
            onPressed: _searching ? null : _search,
            icon: const Icon(Icons.search, size: 18),
            label: Text(_searching ? 'Recherche…' : 'Rechercher un utilisateur',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 12),
          ..._results.map((u) => _SearchUserTile(
                user: u,
                onAdd: () {
                  widget.app.addContact(
                    u['name']?.toString() ?? 'Inconnu',
                    u['id'].toString(),
                    phoneNumber: u['phone_number']?.toString(),
                  );
                  setState(() => _results = []);
                },
                onCall: () => widget.app.call.startOutgoing(
                  u['id'].toString(),
                  targetName: u['name']?.toString(),
                ),
              )),
        ],
        const SizedBox(height: 24),
        if (app.contacts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text('Aucun contact enregistré',
                  style: TextStyle(color: YamColors.muted)),
            ),
          )
        else
          ...app.contacts.map((c) => _ContactTile(app, c, key: ValueKey(c.id))),
      ],
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile(this.app, this.contact, {super.key});

  final AppState app;
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: YamColors.surface,
        borderRadius: kCardRadius,
        border: Border.all(color: YamColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contact.name,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: YamColors.text)),
                const SizedBox(height: 4),
                Text(contact.phoneNumber ?? 'Utilisateur #${contact.userId}',
                    style: mono(size: 13, color: YamColors.muted)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Appeler',
            onPressed: () => app.call.startOutgoing(contact.userId, targetName: contact.name),
            icon: const Icon(Icons.call_rounded, color: YamColors.accent),
          ),
          IconButton(
            tooltip: 'Appel vidéo',
            onPressed: () =>
                app.call.startOutgoing(contact.userId, targetName: contact.name, video: true),
            icon: const Icon(Icons.videocam_rounded, color: YamColors.accent),
          ),
          IconButton(
            tooltip: 'Supprimer',
            onPressed: () => app.removeContact(contact),
            icon: const Icon(Icons.delete_outline, color: YamColors.muted),
          ),
        ],
      ),
    );
  }
}

class _SearchUserTile extends StatelessWidget {
  const _SearchUserTile({required this.user, required this.onAdd, required this.onCall});

  final Map<String, dynamic> user;
  final VoidCallback onAdd;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(user['name']?.toString() ?? 'Inconnu'),
        subtitle: Text(user['phone_number']?.toString() ?? user['username']?.toString() ?? ''),
        trailing: Wrap(
          spacing: 4,
          children: [
            IconButton(onPressed: onAdd, icon: const Icon(Icons.person_add_alt_1)),
            IconButton(onPressed: onCall, icon: const Icon(Icons.call)),
          ],
        ),
      );
}
