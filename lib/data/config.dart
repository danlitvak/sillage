/// Build-time configuration.
///
/// Supplied with `--dart-define`, never committed:
///
///   flutter run -d windows \
///     --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///     --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
///
/// The anon key is PUBLIC by design — it identifies the project, and every
/// table is behind row-level security, so holding it grants nothing. The key
/// that must never appear here is ANTHROPIC_API_KEY: it lives only in the Edge
/// Function's secrets, because anything compiled into the app is extractable
/// from the APK in about thirty seconds.
library;

abstract final class Config {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  /// Supabase renamed this key from "anon" to "publishable"; both names are
  /// accepted here so an older build command keeps working.
  static const _publishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static String get supabaseAnonKey =>
      _publishableKey.isNotEmpty ? _publishableKey : _anonKey;

  /// True when the app has enough to reach a backend at all.
  ///
  /// Checked at startup so a missing define produces one clear screen naming
  /// what to set, rather than an opaque network failure on the first scan.
  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static const missingConfigMessage =
      'Supabase credentials are not set. Pass them at build time:\n\n'
      '  --dart-define=SUPABASE_URL=...\n'
      '  --dart-define=SUPABASE_PUBLISHABLE_KEY=...';
}
