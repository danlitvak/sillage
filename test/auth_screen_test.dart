/// The sign-in screen's two modes.
///
/// No network: these only exercise rendering, the mode switch, and the checks
/// that run before any request. The Supabase client is read inside button
/// handlers only AFTER local validation passes, so a bare ProviderScope is
/// enough — and any test that accidentally reached the network would throw,
/// because nothing is initialised. That is a feature: it proves the local
/// checks fire first.
///
/// What this pins is the contract that came out of a real failure: sign-in and
/// account creation are DISTINCT modes with distinct labels, the user can move
/// between them, sign-in never asks for a second password, creation always
/// does, and neither mode is ever inferred from the other.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillage/features/auth/auth_screen.dart';
import 'package:sillage/theme/theme.dart';

Widget _host() => ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const AuthScreen(),
      ),
    );

Future<void> _toCreate(WidgetTester tester) async {
  await tester.tap(find.text('New here? Create an account'));
  await tester.pump();
}

void main() {
  testWidgets('opens in sign-in mode, with a way to create an account',
      (tester) async {
    await tester.pumpWidget(_host());

    expect(find.text('Sign in'), findsNWidgets(2)); // heading + button
    expect(find.text('New here? Create an account'), findsOneWidget);
    expect(find.text('Create account'), findsNothing);
    // Sign-in asks for the password ONCE. A confirm field there would be
    // friction with no typo to catch — the stored password is the truth.
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Confirm password'), findsNothing);
    expect(find.textContaining('At least six characters'), findsNothing);
  });

  testWidgets('create-account changes heading, button, hint, and adds confirm',
      (tester) async {
    await tester.pumpWidget(_host());
    await _toCreate(tester);

    expect(find.text('Create an account'), findsOneWidget); // heading
    expect(find.text('Create account'), findsOneWidget); // button
    expect(find.text('I already have an account'), findsOneWidget);
    expect(find.text('New here? Create an account'), findsNothing);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('Confirm password'), findsOneWidget);
    expect(find.textContaining('At least six characters'), findsOneWidget);
  });

  testWidgets('and back again, dropping the confirm field', (tester) async {
    await tester.pumpWidget(_host());
    await _toCreate(tester);
    await tester.tap(find.text('I already have an account'));
    await tester.pump();

    expect(find.text('Sign in'), findsNWidgets(2));
    expect(find.text('Create account'), findsNothing);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('the magic-link button stays hidden while SMTP is unconfigured',
      (tester) async {
    await tester.pumpWidget(_host());
    expect(magicLinkEnabled, isFalse);
    expect(find.text('Email me a link instead'), findsNothing);
  });

  testWidgets('sign-in: local validation fires before any network call',
      (tester) async {
    await tester.pumpWidget(_host());
    final fields = find.byType(TextField);

    await tester.enterText(fields.at(0), 'not-an-email');
    await tester.enterText(fields.at(1), 'longenough');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Enter an email address.'), findsOneWidget);

    await tester.enterText(fields.at(0), 'a@b.co');
    await tester.enterText(fields.at(1), 'short');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Passwords need at least six characters.'), findsOneWidget);
  });

  testWidgets('create: mismatched passwords are caught on-device',
      (tester) async {
    // The exact failure that prompted the second field: a password typed once,
    // wrong, and saved. Two fields that disagree must never reach the server.
    await tester.pumpWidget(_host());
    await _toCreate(tester);
    final fields = find.byType(TextField);

    await tester.enterText(fields.at(0), 'a@b.co');
    await tester.enterText(fields.at(1), 'correct-horse');
    await tester.enterText(fields.at(2), 'correct-hors');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pump();
    expect(find.text("The two passwords don't match."), findsOneWidget);
  });

  testWidgets('switching modes clears the error and the confirm field',
      (tester) async {
    await tester.pumpWidget(_host());
    await _toCreate(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'a@b.co');
    await tester.enterText(fields.at(1), 'correct-horse');
    await tester.enterText(fields.at(2), 'nope');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pump();
    expect(find.text("The two passwords don't match."), findsOneWidget);

    await tester.tap(find.text('I already have an account'));
    await tester.pump();
    // A stale error from the other mode would mislead; it must go.
    expect(find.text("The two passwords don't match."), findsNothing);
  });
}
