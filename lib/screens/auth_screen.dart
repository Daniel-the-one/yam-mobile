import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// Portail Sanctum : le mobile ne démarre ni la signalisation ni les appels
/// avant qu'une session par téléphone ait été créée.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.app});

  final AppState app;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _loading = false;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _loading = true);
    try {
      if (_register) {
        await widget.app.register(
          name: _name.text,
          phoneNumber: _phone.text,
          password: _password.text,
          username: _username.text,
        );
      } else {
        await widget.app.login(phoneNumber: _phone.text, password: _password.text);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Yam', style: Theme.of(context).textTheme.headlineMedium),
                        const SizedBox(height: 8),
                        Text(_register ? 'Créez votre compte pour appeler vos contacts.' : 'Connectez-vous pour passer des appels.'),
                        const SizedBox(height: 24),
                        if (_register) ...[
                          TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Nom complet'), validator: _required),
                          const SizedBox(height: 12),
                          TextField(controller: _username, decoration: const InputDecoration(labelText: 'Nom d’utilisateur (facultatif)')),
                          const SizedBox(height: 12),
                        ],
                        TextFormField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Numéro de téléphone'), validator: _required),
                        const SizedBox(height: 12),
                        TextFormField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Mot de passe'), validator: (v) => (v?.length ?? 0) < 8 ? '8 caractères minimum' : null),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _loading ? null : _submit,
                          child: Text(_loading ? 'Connexion…' : (_register ? 'Créer mon compte' : 'Se connecter')),
                        ),
                        TextButton(
                          onPressed: _loading ? null : () => setState(() => _register = !_register),
                          child: Text(_register ? 'J’ai déjà un compte' : 'Créer un compte'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Champ requis' : null;
}
