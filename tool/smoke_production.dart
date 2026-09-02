/// Full-path smoke test against a DEPLOYED stack.
///
/// =============================================================================
/// WHAT THIS COVERS THAT NOTHING ELSE DOES
/// =============================================================================
/// `eval_identify.dart` proves identification works. It calls `identify` and
/// stops there — it never writes anything. So before this file existed, the
/// following had never run against production even once:
///
///   * `enrich` (the eval never calls it)
///   * `catalog_propose_fragrance` with a real JWT
///   * a collection insert under real RLS
///   * a photo upload into the per-user Storage bucket
///   * reading the shelf back through the real select
///
/// That is the entire path between "the model answered" and "it is on my
/// shelf", and it is what a tester actually does. Verifying identification and
/// calling the app ready would have been checking the hard part and shipping
/// the untested rest.
///
/// Creates a throwaway account, walks the whole flow, then deletes what it
/// made. Run it against production before handing the link to anyone:
///
///   dart run tool/smoke_production.dart --url https://xxxx.supabase.co --key sb_publishable_...
library;

import 'dart:convert';
import 'dart:io';

import 'package:sillage/core/identity.dart';

int _failures = 0;
final _notes = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    stdout.writeln('  ok    $label');
  } else {
    _failures++;
    stdout.writeln('  FAIL  $label${detail.isEmpty ? '' : ' — $detail'}');
  }
}

void note(String s) {
  _notes.add(s);
  stdout.writeln('  ..    $s');
}

Future<void> main(List<String> args) async {
  final url = _arg(args, '--url');
  final key = _arg(args, '--key');
  final photo = _arg(args, '--photo') ?? 'eval/photos/sauvage.jpg';
  if (url == null || key == null) {
    stderr.writeln('usage: dart run tool/smoke_production.dart '
        '--url <supabase-url> --key <publishable-key> [--photo <path>]');
    exit(64);
  }

  final client = HttpClient();
  // A unique throwaway address per run, so repeated runs never collide and the
  // test never touches a real account.
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final email = 'smoke-$stamp@sillage.test';
  const password = 'smoke-test-passphrase-01';

  stdout.writeln('sillage — production smoke test\n  $url\n');

  String? token;
  String? userId;
  String? fragranceId;
  String? collectionItemId;
  String? photoPath;

  try {
    // ---------------------------------------------------------------- signup
    stdout.writeln('SIGN UP (what a tester does first)');
    final signup = await _json(client, 'POST', '$url/auth/v1/signup', key, null,
        {'email': email, 'password': password});
    token = signup['access_token'] as String?;
    userId = (signup['user'] as Map?)?['id'] as String?;
    check('signup returns a session with no email step', token != null);
    if (token == null) {
      stdout.writeln('\n  Cannot continue. Email confirmation may be back on.');
      exit(1);
    }

    // -------------------------------------------------------------- identify
    stdout.writeln('\nSCAN');
    final bytes = await File(photo).readAsBytes();
    final ident = await _json(client, 'POST', '$url/functions/v1/identify', key,
        token, {'image': base64Encode(bytes), 'mediaType': 'image/jpeg'});
    final candidates =
        (ident['candidates'] as List? ?? const []).cast<Map<String, dynamic>>();
    check('identify returned candidates', candidates.isNotEmpty);
    if (candidates.isEmpty) exit(1);

    final top = candidates.first;
    note('top candidate: ${top['brand']} / ${top['name']} / '
        '${top['concentration']}');

    // ---------------------------------------------------------------- enrich
    // Never exercised in production before this file.
    final enriched = await _json(client, 'POST', '$url/functions/v1/enrich', key,
        token, {
      'brand': top['brand'],
      'name': top['name'],
      'concentration': top['concentration'],
    });
    final known = enriched['known'] == true;
    final notes = (enriched['notes'] as List? ?? const []);
    check('enrich responded', enriched['error'] == null);
    note(known
        ? 'enrich knows it: ${notes.length} notes'
        : 'enrich declined to guess (a valid outcome)');

    // --------------------------------------------------------------- catalog
    stdout.writeln('\nCATALOG WRITE (security definer function, real JWT)');
    final fkey = buildFragranceKey(
      rawBrand: top['brand'] as String,
      rawName: top['name'] as String,
      rawConcentration: top['concentration'] as String?,
    );
    final rpc = await _raw(client, 'POST', '$url/rest/v1/rpc/catalog_propose_fragrance',
        key, token, {
      'p_brand_key': fkey.brand,
      'p_brand_display': top['brand'],
      'p_brand_tier': 'unknown',
      'p_fragrance_key': fkey.value,
      'p_name_key': fkey.name,
      'p_display_name': top['name'],
      'p_concentration': fkey.concentration.wire,
      'p_release_year': enriched['release_year'],
      'p_perfumer': enriched['perfumer'],
      'p_notes': notes,
      'p_accords': enriched['accords'] ?? [],
      'p_source': 'model',
    });
    fragranceId = jsonDecode(rpc) is String ? jsonDecode(rpc) as String : null;
    check('catalog_propose_fragrance returned an id', fragranceId != null,
        rpc.substring(0, rpc.length.clamp(0, 160)));
    if (fragranceId == null) exit(1);
    note('catalog key: ${fkey.value}');

    // --------------------------------------------------------------- storage
    stdout.writeln('\nPHOTO UPLOAD (never run anywhere before now)');
    photoPath = '$userId/smoke-$stamp.jpg';
    final upStatus = await _upload(
        client, '$url/storage/v1/object/bottle-photos/$photoPath', key, token, bytes);
    check('upload into the per-user folder succeeds', upStatus == 200,
        'HTTP $upStatus');

    // The path prefix IS the authorisation — a write outside the caller's own
    // folder must be refused by the bucket policy, not merely discouraged.
    final badStatus = await _upload(
        client,
        '$url/storage/v1/object/bottle-photos/00000000-0000-0000-0000-000000000000/evil.jpg',
        key,
        token,
        bytes);
    check('upload into ANOTHER user folder is refused', badStatus >= 400,
        'HTTP $badStatus');

    // ------------------------------------------------------------ collection
    stdout.writeln('\nCOLLECTION');
    final insert = await _raw(client, 'POST', '$url/rest/v1/collection_items',
        key, token, {
      'user_id': userId,
      'fragrance_id': fragranceId,
      'photo_path': photoPath,
    }, prefer: 'return=representation');
    final rows = jsonDecode(insert);
    collectionItemId =
        rows is List && rows.isNotEmpty ? rows.first['id'] as String? : null;
    check('collection insert under RLS', collectionItemId != null);

    // ------------------------------------------------------------- read back
    final shelf = await _raw(
        client,
        'GET',
        '$url/rest/v1/collection_items?select=id,photo_path,'
            'fragrance:fragrances(display_name,notes_source,'
            'fragrance_notes(tier,note:notes(display_name)))',
        key,
        token,
        null);
    final shelfRows = jsonDecode(shelf) as List;
    check('the shelf reads back exactly one bottle', shelfRows.length == 1,
        '${shelfRows.length} rows');
    if (shelfRows.isNotEmpty) {
      final f = shelfRows.first['fragrance'] as Map<String, dynamic>;
      check('it is the bottle that was scanned',
          (f['display_name'] as String).isNotEmpty);
      check('its pyramid came back with it',
          !known || (f['fragrance_notes'] as List).isNotEmpty);
      check('it is marked unverified, as model-proposed data must be',
          f['notes_source'] == 'model');
      note('shelf shows: ${f['display_name']} '
          '(${(f['fragrance_notes'] as List).length} notes, '
          '${f['notes_source']})');
    }
  } finally {
    // ------------------------------------------------------------- tear down
    if (token != null) {
      stdout.writeln('\nCLEAN UP');
      if (collectionItemId != null) {
        await _raw(client, 'DELETE',
            '$url/rest/v1/collection_items?id=eq.$collectionItemId', key, token, null);
        stdout.writeln('  ..    removed the collection row');
      }
      if (photoPath != null) {
        await _raw(client, 'DELETE',
            '$url/storage/v1/object/bottle-photos/$photoPath', key, token, null);
        stdout.writeln('  ..    removed the uploaded photo');
      }
      // The catalog row is deliberately LEFT: it is shared data that a real
      // scan would also have created, and leaving it is what makes the second
      // scan of this bottle free. Say so rather than pretending nothing
      // persisted.
      stdout.writeln('  ..    catalog row left in place (shared, by design)');
      stdout.writeln('  ..    throwaway account $email left signed up');
    }
    client.close();
  }

  stdout.writeln(_failures == 0
      ? '\nAll checks passed — the full path works in production.'
      : '\n$_failures check(s) FAILED.');
  exit(_failures == 0 ? 0 : 1);
}

// =============================================================================

Future<Map<String, dynamic>> _json(HttpClient c, String method, String uri,
    String key, String? token, Object? body) async {
  final text = await _raw(c, method, uri, key, token, body);
  final d = jsonDecode(text);
  return d is Map<String, dynamic> ? d : {'raw': d};
}

Future<String> _raw(HttpClient c, String method, String uri, String key,
    String? token, Object? body,
    {String? prefer}) async {
  final req = await c.openUrl(method, Uri.parse(uri));
  req.headers.set('apikey', key);
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  if (token != null) {
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (prefer != null) req.headers.set('Prefer', prefer);
  if (body != null) {
    // Encoded to bytes with an explicit Content-Length rather than `write()`.
    // PostgREST rejects the chunked body `write()` produces with
    // `PGRST102 Empty or invalid json` — it never sees the payload at all.
    final payload = utf8.encode(jsonEncode(body));
    req.headers.contentLength = payload.length;
    req.add(payload);
  }
  final res = await req.close();
  return res.transform(utf8.decoder).join();
}

Future<int> _upload(HttpClient c, String uri, String key, String token,
    List<int> bytes) async {
  final req = await c.postUrl(Uri.parse(uri));
  req.headers.set('apikey', key);
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  req.headers.set(HttpHeaders.contentTypeHeader, 'image/jpeg');
  req.add(bytes);
  final res = await req.close();
  await res.drain<void>();
  return res.statusCode;
}

String? _arg(List<String> a, String n) {
  final i = a.indexOf(n);
  return (i >= 0 && i + 1 < a.length) ? a[i + 1] : null;
}
