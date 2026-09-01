/// End-to-end check of everything except identification, with no GUI.
///
/// =============================================================================
/// WHY THIS EXISTS ALONGSIDE THE UNIT TESTS
/// =============================================================================
/// `taste_test.dart` proves the arithmetic against hand-built fixtures. It says
/// nothing about whether the PostgREST selects in `repository.dart` return the
/// shape `mapping.dart` expects, whether RLS lets a signed-in user read their
/// own shelf, or whether the detectors fire on real rows.
///
/// This script closes that gap: it signs in over the real auth endpoint, pulls
/// the collection and catalog through the SAME selects and the SAME row-mapping
/// the app uses, and runs the real profile and recommender over the result. If
/// the column list drifts from the mapper, this fails; a unit test never would.
///
/// Deliberately no `supabase_flutter`: that package needs Flutter bindings, and
/// requiring a device to check the data layer would defeat the point.
///
/// Usage (against `supabase start`):
///
///   dart run tool/check_recommender.dart
///   dart run tool/check_recommender.dart --url http://127.0.0.1:54321 --key `<publishable>`
library;

import 'dart:convert';
import 'dart:io';

import 'package:sillage/core/models.dart';
import 'package:sillage/core/recommend.dart';
import 'package:sillage/core/taste.dart';
import 'package:sillage/data/mapping.dart';

/// Defaults match the fixed local-stack values `supabase start` prints. These
/// are not secrets — the local keys are the same on every machine.
const _defaultUrl = 'http://127.0.0.1:54321';
const _defaultKey = 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const _devEmail = 'dev@sillage.local';
const _devPassword = 'sillage123';

/// Kept byte-identical to `_fragranceSelect` in repository.dart. If the two
/// drift, this script stops testing what the app actually runs — so any change
/// there belongs here too.
const _fragranceSelect =
    'id,key,name_key,concentration,display_name,release_year,perfumer,'
    'notes_source,'
    'brand:brands(key,display_name,tier),'
    'fragrance_notes(tier,position,note:notes(key,display_name,family)),'
    'fragrance_accords(weight,accord:accords(key,display_name)),'
    'clone_of!clone_of_clone_id_fkey(original_id)';

int _failures = 0;

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    stdout.writeln('  ok    $label');
  } else {
    _failures++;
    stdout.writeln('  FAIL  $label${detail.isEmpty ? '' : ' — $detail'}');
  }
}

Future<void> main(List<String> args) async {
  final url = _arg(args, '--url') ?? _defaultUrl;
  final key = _arg(args, '--key') ?? _defaultKey;
  final client = HttpClient();

  stdout.writeln('sillage — live data-layer check against $url\n');

  try {
    // -----------------------------------------------------------------------
    stdout.writeln('AUTH');
    final token = await _signIn(client, url, key);
    check('password sign-in returns a session', token != null);
    if (token == null) {
      stdout.writeln('\nCannot continue without a session.');
      exit(1);
    }

    // -----------------------------------------------------------------------
    stdout.writeln('\nREADS (same selects and mapper the app uses)');
    final catalogRows = await _get(
      client, url, key, token,
      '/rest/v1/fragrances?select=$_fragranceSelect&limit=600',
    );
    final catalog =
        catalogRows.map(fragranceFromRow).whereType<Fragrance>().toList();
    check('catalog rows parse', catalog.length == catalogRows.length,
        '${catalog.length}/${catalogRows.length} mapped');
    check('catalog is non-empty', catalog.isNotEmpty, '${catalog.length} rows');

    final collectionRows = await _get(
      client, url, key, token,
      '/rest/v1/collection_items?select=id,status,photo_path,bottle_ml,'
      'acquired_on,rating,note,fragrance:fragrances($_fragranceSelect)',
    );
    final items = collectionRows
        .map(collectionItemFromRow)
        .whereType<CollectionItem>()
        .toList();
    check('collection rows parse', items.length == collectionRows.length,
        '${items.length}/${collectionRows.length} mapped');

    // The mapper silently returns null on a shape mismatch, so an empty result
    // here would otherwise look like an empty shelf rather than a broken query.
    check('every collection item carries a fragrance',
        items.every((i) => i.fragrance.displayName.isNotEmpty));
    check('note pyramids came through',
        items.any((i) => i.fragrance.notes.isNotEmpty));
    check('accords came through',
        items.any((i) => i.fragrance.accords.isNotEmpty));
    check('clone edges came through',
        items.any((i) => i.fragrance.isClone));

    // -----------------------------------------------------------------------
    stdout.writeln('\nTASTE PROFILE');
    final stats = CatalogStats.from(catalog);
    final profile = buildTasteProfile(items: items, stats: stats);

    stdout.writeln('  ${profile.itemCount} bottles, '
        '${stats.documentCount} in catalog, '
        '${profile.unverifiedCount} unverified pyramids');
    for (final p in profile.patterns) {
      stdout.writeln('    - [${p.kind.name}] ${p.headline}: ${p.detail}');
    }

    check('the profile has bottles', profile.itemCount > 0);
    check('patterns fired on real rows', profile.patterns.isNotEmpty);
    check('house loyalty detected',
        profile.patterns.any((p) => p.kind == PatternKind.houseLoyalist));
    check('note obsession detected',
        profile.patterns.any((p) => p.kind == PatternKind.noteObsession));
    check('an accord gap detected',
        profile.patterns.any((p) => p.kind == PatternKind.accordGap));
    // The seeded shelf is 2 clones of 7, under the >50% threshold. Asserting it
    // does NOT fire is as important as asserting the others do — a detector
    // that always fires detects nothing.
    check('clone-buyer correctly does NOT fire at 2 of 7',
        !profile.patterns.any((p) => p.kind == PatternKind.cloneBuyer));
    check('the profile reports its own unverified foundation',
        profile.patterns.any((p) => p.kind == PatternKind.unverifiedData));

    // -----------------------------------------------------------------------
    stdout.writeln('\nRECOMMENDATIONS');
    final owned = items.map((i) => i.fragrance.id).toSet();
    final groups = recommend(RecommendationInput(
      profile: profile,
      owned: items,
      candidates: catalog,
      stats: stats,
    ));

    var total = 0;
    for (final entry in groups.entries) {
      if (entry.value.isEmpty) continue;
      stdout.writeln('  ${entry.key.label}:');
      for (final r in entry.value) {
        total++;
        stdout.writeln('    ${r.fragrance.displayName} '
            '(${r.score.toStringAsFixed(2)}) — ${r.explanation}');
      }
    }

    check('recommendations were produced', total > 0, '$total');
    check('nothing already owned is recommended',
        groups.values.expand((g) => g).every((r) => !owned.contains(r.fragrance.id)));
    check('every recommendation carries an explanation',
        groups.values.expand((g) => g).every((r) => r.explanation.trim().isNotEmpty));
    check('every score is in range',
        groups.values.expand((g) => g).every((r) => r.score >= 0 && r.score <= 1));
    check('the gap strategy points at the missing accord',
        (groups[RecStrategy.gap] ?? const []).isNotEmpty);
    check('no fragrance appears twice within a strategy', groups.values.every((g) {
      final ids = g.map((r) => r.fragrance.id).toList();
      return ids.length == ids.toSet().length;
    }));

    // -----------------------------------------------------------------------
    stdout.writeln('\nRLS');
    final anonRows = await _get(client, url, key, null,
        '/rest/v1/collection_items?select=id', allowFailure: true);
    check('an unauthenticated caller sees no collection rows', anonRows.isEmpty,
        '${anonRows.length} rows leaked');
  } finally {
    client.close();
  }

  stdout.writeln(_failures == 0
      ? '\nAll checks passed.'
      : '\n$_failures check(s) FAILED.');
  exit(_failures == 0 ? 0 : 1);
}

// =============================================================================

Future<String?> _signIn(HttpClient client, String url, String key) async {
  final req = await client
      .postUrl(Uri.parse('$url/auth/v1/token?grant_type=password'));
  req.headers
    ..set('apikey', key)
    ..set(HttpHeaders.contentTypeHeader, 'application/json');
  req.write(jsonEncode({'email': _devEmail, 'password': _devPassword}));
  final res = await req.close();
  final text = await res.transform(utf8.decoder).join();
  if (res.statusCode != 200) {
    stdout.writeln('  (auth HTTP ${res.statusCode}: ${text.substring(0, text.length.clamp(0, 200))})');
    return null;
  }
  return (jsonDecode(text) as Map<String, dynamic>)['access_token'] as String?;
}

Future<List<Map<String, dynamic>>> _get(
  HttpClient client,
  String url,
  String key,
  String? token,
  String path, {
  bool allowFailure = false,
}) async {
  final req = await client.getUrl(Uri.parse('$url$path'));
  req.headers.set('apikey', key);
  if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  final res = await req.close();
  final text = await res.transform(utf8.decoder).join();
  if (res.statusCode != 200) {
    if (allowFailure) return const [];
    throw HttpException('HTTP ${res.statusCode} on $path: $text');
  }
  final decoded = jsonDecode(text);
  if (decoded is! List) return const [];
  return decoded.cast<Map<String, dynamic>>();
}

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
}
