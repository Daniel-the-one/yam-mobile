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
  final _nameCtrl = TextEditingController();
  final _idCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }

  void _save() {
    widget.app.addContact(_nameCtrl.text, _idCtrl.text);
    _nameCtrl.clear();
    _idCtrl.clear();
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
          controller: _nameCtrl,
          textInputAction: TextInputAction.next,
          decoration: _deco('Nom du contact'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _idCtrl,
          style: mono(size: 14, color: YamColors.text),
          decoration: _deco('device-a1b2c3d4', monoStyle: true),
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
            onPressed: _save,
            icon: const Icon(Icons.person_add_alt_1, size: 18),
            label: const Text('Enregistrer le contact',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
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
                Text(contact.deviceId,
                    style: mono(size: 13, color: YamColors.muted)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Appeler',
            onPressed: () => app.call.startOutgoing(contact.deviceId),
            icon: const Icon(Icons.call_rounded, color: YamColors.accent),
          ),
          IconButton(
            tooltip: 'Appel vidéo',
            onPressed: () =>
                app.call.startOutgoing(contact.deviceId, video: true),
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
