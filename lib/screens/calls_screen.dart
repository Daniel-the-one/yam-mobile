import 'package:flutter/material.dart';

import '../models/missed_call.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Historique des appels (manqués avec badge + émis terminés).
class CallsScreen extends StatelessWidget {
  const CallsScreen({super.key, required this.app});

  final AppState app;

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (app.calls.isEmpty) {
      return const Center(
        child: Text('Aucun appel pour le moment',
            style: TextStyle(color: YamColors.muted)),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: app.calls
          .map((r) => _CallTile(app, r, fmt: _fmt, key: ValueKey(r.id)))
          .toList(),
    );
  }
}

class _CallTile extends StatelessWidget {
  const _CallTile(this.app, this.record, {super.key, required this.fmt});

  final AppState app;
  final CallRecord record;
  final String Function(DateTime) fmt;

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
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        record.peerName.isEmpty ? record.peerId : record.peerName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color:
                              record.missed ? YamColors.danger : YamColors.text,
                        ),
                      ),
                    ),
                    if (record.missed) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: YamColors.danger.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text('Manqué',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: YamColors.danger)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${record.peerId} · ${fmt(record.at)}',
                  style: mono(size: 12, color: YamColors.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Rappeler',
            onPressed: () => app.call.startOutgoing(record.peerId),
            icon: const Icon(Icons.call_rounded, color: YamColors.accent),
          ),
          IconButton(
            tooltip: 'Effacer',
            onPressed: () => app.removeCall(record),
            icon: const Icon(Icons.delete_outline, color: YamColors.muted),
          ),
        ],
      ),
    );
  }
}
