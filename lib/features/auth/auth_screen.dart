/// Sign in, or create an account — two explicit paths, never guessed.
///
/// =============================================================================
/// WHY THESE ARE SEPARATE, AND WHY THEY USED NOT TO BE
/// =============================================================================
/// The first version had one button. It tried to sign in, and if that failed
/// it created the account — on the theory that a person knows their email
/// address, not whether this app has seen it before. That theory was wrong in
/// two ways, both found by the app's own author on a second device:
///
///   1. Supabase returns the SAME error for "no such account" and "wrong
///      password", on purpose, so callers cannot enumerate users. The fallback
///      therefore fired on every mistyped password, tried to sign up an address
///      that already existed, and surfaced "User already registered" to
///      someone who was simply trying to sign in.
///
///   2. Worse: a mistyped EMAIL on sign-in did not fail at all. It quietly
///      created a fresh, empty account under the typo.
///
/// So: sign-in never creates anything, and its failure says what it is. Account
/// creation is its own mode, one tap away, asks for the password twice, and says
/// so when the address is already taken. Everyone knows which of the two they
/// are.
///
/// The second password field is the defence against the failure that actually
/// happened: a password typed once, wrong, and saved. It catches a TYPO. It does
/// not catch FORGETTING — only a reset flow does that, and a reset needs the
/// SMTP this project does not yet have. The create-account hint says so.
///
/// =============================================================================
/// WHY PASSWORD AND NOT MAGIC LINK
/// =============================================================================
/// Magic link is nicer and it is the one that breaks first here: this project
/// has no SMTP provider, and Supabase's built-in sender is throttled to a
/// handful of messages an hour. It also cannot complete on a desktop build at
/// all. The code path is kept behind [magicLinkEnabled] for the day Resend is
/// wired up.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Whether to offer the magic-link path at all. See the header.
const bool magicLinkEnabled = false;

enum _Mode { signIn, createAccount }

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  _Mode _mode = _Mode.signIn;
  bool _busy = false;
  String? _error;

  /// Set when creation succeeded but returned no session — confirmations are
  /// on and the account is pending an email that may never arrive.
  bool _pendingConfirmation = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// Everything that can be checked without a network. Ordered so the first
  /// message a person sees is about the field they are most likely still on.
  bool _validate() {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter an email address.');
      return false;
    }
    if (_password.text.length < 6) {
      setState(() => _error = 'Passwords need at least six characters.');
      return false;
    }
    if (_mode == _Mode.createAccount && _confirm.text != _password.text) {
      setState(() => _error = "The two passwords don't match.");
      return false;
    }
    return true;
  }

  Future<void> _submit() async {
    if (!_validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final auth = ref.read(supabaseProvider).auth;
    final email = _email.text.trim();
    final password = _password.text;

    try {
      switch (_mode) {
        case _Mode.signIn:
          // Never falls through to creation. A failure here is a failure.
          await auth.signInWithPassword(email: email, password: password);

        case _Mode.createAccount:
          final res = await auth.signUp(email: email, password: password);
          if (res.session == null && mounted) {
            setState(() => _pendingConfirmation = true);
          }
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One sentence per failure, written for the person at the keyboard.
  ///
  /// The wrong-password case is the most common error in any sign-in flow,
  /// and it is the one the old single-button design turned into "User
  /// already registered". It now says what it is, and mentions the one thing
  /// that will actually bite: there is no reset yet.
  String _describe(AuthException e) {
    final m = e.message.toLowerCase();
    if (m.contains('invalid login credentials')) {
      return 'Wrong email or password. There is no password reset yet, so if '
          'you have forgotten it, create a new account with a different '
          'address.';
    }
    if (m.contains('already registered') || m.contains('already exists')) {
      return 'That email already has an account. Sign in instead.';
    }
    if (m.contains('rate limit') || m.contains('too many')) {
      return 'Too many attempts. Wait a minute and try again.';
    }
    return e.message;
  }

  void _switchMode() => setState(() {
        _mode = _mode == _Mode.signIn ? _Mode.createAccount : _Mode.signIn;
        _error = null;
        _confirm.clear();
      });

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    final creating = _mode == _Mode.createAccount;

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
                  Text('sillage',
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: Space.xs),
                  Text(
                    'The trail a fragrance leaves behind.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: Space.xxl),

                  if (_pendingConfirmation) ...[
                    Text('Check your email',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: Space.sm),
                    Text(
                      'A confirmation is on its way to ${_email.text.trim()}.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: Space.lg),
                    OutlinedButton(
                      onPressed: () =>
                          setState(() => _pendingConfirmation = false),
                      child: const Text('Use a different address'),
                    ),
                  ] else ...[
                    // The mode is stated as a heading, not inferred from a
                    // button label alone, so someone landing on the wrong one
                    // sees it before they type.
                    Text(
                      creating ? 'Create an account' : 'Sign in',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: Space.md),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: Space.md),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: [
                        creating
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      decoration: InputDecoration(
                        labelText: 'Password',
                        // Only when creating: that is when the rule can still
                        // be acted on, and when there is no reset to fall
                        // back on. DESIGN.md — explain what changes a choice,
                        // never what a control does.
                        helperText: creating
                            ? 'At least six characters. There is no reset yet, '
                                'so keep it somewhere.'
                            : null,
                        helperMaxLines: 2,
                      ),
                      textInputAction: creating
                          ? TextInputAction.next
                          : TextInputAction.done,
                      onSubmitted: (_) => creating ? null : _submit(),
                    ),
                    if (creating) ...[
                      const SizedBox(height: Space.md),
                      TextField(
                        controller: _confirm,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: const InputDecoration(
                          labelText: 'Confirm password',
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                    ],
                    const SizedBox(height: Space.md),
                    SizedBox(
                      width: double.infinity,
                      child: Column(
                        children: [
                          FilledButton(
                            onPressed: _busy ? null : _submit,
                            child: Text(
                                creating ? 'Create account' : 'Sign in'),
                          ),
                          // Under the control, not inside it: a spinner glyph
                          // needs horizontal room a button label already has.
                          if (_busy) const BusyBar(),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    TextButton(
                      onPressed: _busy ? null : _switchMode,
                      child: Text(
                        creating
                            ? 'I already have an account'
                            : 'New here? Create an account',
                      ),
                    ),
                    if (magicLinkEnabled) ...[
                      const SizedBox(height: Space.sm),
                      TextButton(
                        onPressed: _busy ? null : _sendMagicLink,
                        child: const Text('Email me a link instead'),
                      ),
                    ],
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

  /// Kept intact behind [magicLinkEnabled]; see the header.
  Future<void> _sendMagicLink() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter an email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).auth.signInWithOtp(email: email);
      if (mounted) setState(() => _pendingConfirmation = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not send the link. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
