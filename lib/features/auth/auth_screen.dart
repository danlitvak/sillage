import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Sign in, two ways.
///
/// =============================================================================
/// WHY THERE IS A PASSWORD OPTION AT ALL
/// =============================================================================
/// Magic link is the nicer flow and it is the default on mobile — no password to
/// handle, store, or get wrong (the `sayable-beta` pattern).
///
/// But it cannot complete on a DESKTOP build. The link opens in a browser, and a
/// browser has no way to hand the session back to a Windows app unless a custom
/// URI scheme is registered and the app happens to be running to receive it.
/// Windows is this project's development harness — an emulator's camera cannot
/// photograph a bottle — so an auth flow that only works on a phone would mean
/// the harness could not sign in at all.
///
/// Both are offered on every platform rather than branching: the desktop case is
/// what forced the second path, but plenty of people simply prefer a password,
/// and one screen that behaves the same everywhere is easier to reason about
/// than two.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _sending = false;
  String? _error;
  bool _sent = false;

  /// Password is the default on desktop, where a magic link cannot complete.
  bool _usePassword = !kIsWeb &&
      defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Signs in, falling back to creating the account when there is not one.
  ///
  /// One button rather than a sign-in/sign-up toggle: a person knows their email
  /// address, not whether this particular app has seen it before, and making
  /// them guess produces a wrong-looking error for a perfectly correct action.
  Future<void> _passwordSignIn() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter an email address.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Passwords need at least six characters.');
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    final auth = ref.read(supabaseProvider).auth;
    try {
      await auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      if (e.message.toLowerCase().contains('invalid login credentials')) {
        try {
          final res = await auth.signUp(email: email, password: password);
          // A null session means confirmations are on and the account is
          // pending — say so rather than leaving the screen looking stuck.
          if (res.session == null && mounted) setState(() => _sent = true);
        } on AuthException catch (e2) {
          if (mounted) setState(() => _error = e2.message);
        }
      } else if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) =>
                          _usePassword ? _passwordSignIn() : _send(),
                    ),
                    if (_usePassword) ...[
                      const SizedBox(height: Space.md),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        decoration: const InputDecoration(labelText: 'Password'),
                        onSubmitted: (_) => _passwordSignIn(),
                      ),
                    ],
                    const SizedBox(height: Space.md),
                    SizedBox(
                      width: double.infinity,
                      child: Column(
                        children: [
                          FilledButton(
                            onPressed: _sending
                                ? null
                                : (_usePassword ? _passwordSignIn : _send),
                            child: Text(
                              _usePassword ? 'Sign in' : 'Send sign-in link',
                            ),
                          ),
                          // The busy signal sits under the control rather than
                          // inside it: a spinner glyph needs horizontal room a
                          // button label already occupies.
                          if (_sending) const BusyBar(),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    TextButton(
                      onPressed: _sending
                          ? null
                          : () => setState(() {
                                _usePassword = !_usePassword;
                                _error = null;
                              }),
                      child: Text(
                        _usePassword
                            ? 'Email me a link instead'
                            : 'Use a password instead',
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
