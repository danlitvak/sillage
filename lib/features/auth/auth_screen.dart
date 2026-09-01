import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Magic-link sign in — the `sayable-beta` pattern.
///
/// No password field, so there is no password to handle, store, or get wrong.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _email = TextEditingController();
  bool _sending = false;
  String? _error;
  bool _sent = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter an email address.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).auth.signInWithOtp(email: email);
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not send the link. $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('sillage', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: Space.xs),
                  Text(
                    'The trail a fragrance leaves behind.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: Space.xxl),

                  if (_sent) ...[
                    Text('Check your email',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: Space.sm),
                    Text(
                      'A sign-in link is on its way to ${_email.text.trim()}.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: Space.lg),
                    OutlinedButton(
                      onPressed: () => setState(() => _sent = false),
                      child: const Text('Use a different address'),
                    ),
                  ] else ...[
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email'),
                      onSubmitted: (_) => _send(),
                    ),
                    const SizedBox(height: Space.md),
                    SizedBox(
                      width: double.infinity,
                      child: Column(
                        children: [
                          FilledButton(
                            onPressed: _sending ? null : _send,
                            child: const Text('Send sign-in link'),
                          ),
                          // The busy signal sits under the control rather than
                          // inside it: a spinner glyph needs horizontal room a
                          // button label already occupies.
                          if (_sending) const BusyBar(),
                        ],
                      ),
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: Space.md),
                    Text(
                      _error!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: tokens.destructive),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
