import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Sign in, two ways — password by default, magic link one tap away.
///
/// =============================================================================
/// WHY PASSWORD IS THE DEFAULT DESPITE BEING THE WORSE FLOW
/// =============================================================================
/// Magic link is nicer: nothing to handle, store, or get wrong (the
/// `sayable-beta` pattern). It is also the one that breaks first here, for two
/// independent reasons:
///
///   NO SMTP.     Supabase's built-in sender is throttled to a handful of
///                messages an hour. Fine for one developer; the moment several
///                people sign up at once they tap "Send sign-in link", nothing
///                arrives, and the screen offers no way forward.
///   NO DESKTOP.  A link opens a browser, and a browser cannot hand the session
///                back to a Windows app without a registered URI scheme. Windows
///                is this project's development harness, so an auth flow that
///                only works on a phone would lock the harness out entirely.
///
/// Both paths are offered on every platform rather than branching by target: one
/// screen that behaves the same everywhere is easier to reason about, and plenty
/// of people simply prefer a password. Flip the default back once a real sender
/// (Resend) is configured.
/// Whether to offer the magic-link path at all.
///
/// OFF, because an option that cannot work is worse than no option. With no
/// SMTP provider configured, tapping "Email me a link instead" sends a request
/// into Supabase's throttled built-in sender, shows "Check your email", and
/// nothing ever arrives — leaving a tester on a dead-end screen with no way
/// back to the flow that does work.
///
/// The code path is kept intact rather than deleted: turn this to `true` the
/// day a real sender (Resend) is wired up, and the button returns.
const bool magicLinkEnabled = false;

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

  /// Password is the default EVERYWHERE, for now.
  ///
  /// Not because it is the nicer flow — magic link is — but because magic link
  /// depends on email actually arriving, and this project has not configured an
  /// SMTP provider. Supabase's built-in sender is throttled to a handful of
  /// messages an hour, which is fine for one developer and breaks the moment
  /// several people sign up at once: they tap "Send sign-in link", nothing
  /// arrives, and there is no way forward from that screen.
  ///
  /// On desktop it would fail regardless — a browser cannot hand the session
  /// back to a Windows app without a registered URI scheme.
  ///
  /// Magic link stays one tap away and should become the default again once a
  /// real sender (Resend) is wired up.
  bool _usePassword = true;

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
                    if (magicLinkEnabled) ...[
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
                    const SizedBox(height: Space.md),
                    // No password-reset flow exists yet, and it would need the
                    // same SMTP this app does not have. Saying so is better
                    // than a tester discovering it while locked out.
                    Text(
                      'No password reset yet — keep the one you pick.',
                      style: Theme.of(context).textTheme.bodySmall,
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
