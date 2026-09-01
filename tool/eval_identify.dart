/// Identification accuracy harness.
///
/// =============================================================================
/// WHY THIS EXISTS
/// =============================================================================
/// Everything else in this project can be unit-tested. Identification cannot:
/// it depends on a model reading a real photograph of a real bottle in real
/// light, and no fixture reproduces that.
///
/// So the only honest way to say how well it works is to measure it against
/// photographs of bottles whose identity is known — and to report the number
/// rather than assert a claim in a README. Without this file, "identification
/// works well" is an opinion.
///
/// =============================================================================
/// WHAT IT MEASURES, AND WHY IT IS GRADED THIS WAY
/// =============================================================================
/// Grading runs through `buildFragranceKey` — the same normalisation the app
/// uses — rather than comparing strings. That is deliberate: a candidate of
/// "Christian Dior / Sauvage Eau de Parfum" against an expected "Dior / Sauvage
/// EDP" is a CORRECT identification, and a string comparison would score it
/// wrong. What matters is whether the scan lands on the right catalog row.
///
/// Four numbers are reported, because they fail differently:
///
///   top-1        the first candidate is the right row
///   top-3        the right row is somewhere in the shortlist — this is the
///                number that matters for the actual UX, since the user picks
///   brand        the house was right, whatever else was wrong
///   concentration the strength was right — expected to be the WEAKEST of the
///                four, since it is small type that a photo often cannot
///                resolve, and the design treats "unknown" as a valid answer
///
/// A separate `declined` count tracks scans that returned no candidates at all.
/// Those are not failures: refusing to guess is designed behaviour, and a
/// harness that scored them as wrong would push the prompt toward confident
/// invention — the exact failure this project is built to avoid.
///
/// =============================================================================
/// USAGE
/// =============================================================================
///   1. Put photographs in eval/photos/.
///   2. Write eval/manifest.json:
///        [
///          {"file": "sauvage-edp.jpg", "brand": "Dior",
///           "name": "Sauvage", "concentration": "edp"},
///          ...
///        ]
///   3. Get an access token for a signed-in user (the app prints one in debug,
///      or use the Supabase dashboard), then:
///
///        dart run tool/eval_identify.dart \
///          --url https://xxxx.supabase.co \
///          --token <access-token>
///
/// Nothing here writes to the catalog or the collection — it calls `identify`
/// only, so running it repeatedly costs model calls and changes no data.
library;

import 'dart:convert';
import 'dart:io';

import 'package:sillage/core/identity.dart';

void main(List<String> args) async {
  final options = _parseArgs(args);
  if (options == null) {
    stderr.writeln(
      'usage: dart run tool/eval_identify.dart --url <supabase-url> '
      '--token <access-token> [--manifest eval/manifest.json] [--limit N]',
    );
    exit(64);
  }

  final manifestFile = File(options.manifestPath);
  if (!manifestFile.existsSync()) {
    stderr.writeln('No manifest at ${options.manifestPath}.');
    stderr.writeln('See the usage note at the top of this file.');
    exit(66);
  }

  final entries = (jsonDecode(await manifestFile.readAsString()) as List)
      .cast<Map<String, dynamic>>()
      .take(options.limit)
      .toList();

  if (entries.isEmpty) {
    stderr.writeln('The manifest is empty — nothing to evaluate.');
    exit(66);
  }

  final photoDir = Directory(options.manifestPath).parent.path;
  final client = HttpClient();
  final results = <_Result>[];

  stdout.writeln('Evaluating ${entries.length} photographs...\n');

  for (final entry in entries) {
    final fileName = entry['file'] as String;
    final photo = File('$photoDir/photos/$fileName');
    if (!photo.existsSync()) {
      stdout.writeln('  SKIP  $fileName (not found)');
      continue;
    }

    final expected = buildFragranceKey(
      rawBrand: entry['brand'] as String,
      rawName: entry['name'] as String,
      rawConcentration: entry['concentration'] as String?,
    );

    try {
      final response = await _identify(
        client: client,
        url: options.url,
        token: options.token,
        bytes: await photo.readAsBytes(),
      );
      final result = _grade(fileName, expected, response);
      results.add(result);
      stdout.writeln('  ${result.mark}  $fileName${result.detail}');
    } catch (e) {
      stdout.writeln('  ERR   $fileName — $e');
      results.add(_Result(
        file: fileName,
        declined: false,
        top1: false,
        top3: false,
        brand: false,
        concentration: false,
        errored: true,
        detail: ' ($e)',
      ));
    }
  }

  client.close();
  _report(results);
}

// =============================================================================

class _Result {
  _Result({
    required this.file,
    required this.declined,
    required this.top1,
    required this.top3,
    required this.brand,
    required this.concentration,
    this.errored = false,
    this.detail = '',
  });

  final String file;

  /// Returned no candidates. Designed behaviour, reported separately.
  final bool declined;
  final bool top1;
  final bool top3;
  final bool brand;
  final bool concentration;
  final bool errored;
  final String detail;

  String get mark {
    if (errored) return 'ERR  ';
    if (declined) return 'PASS ';
    if (top1) return 'HIT  ';
    if (top3) return 'IN-3 ';
    return 'MISS ';
  }
}

_Result _grade(String file, FragranceKey expected, Map<String, dynamic> body) {
  final candidates = (body['candidates'] as List? ?? const [])
      .cast<Map<String, dynamic>>();

  if (candidates.isEmpty) {
    return _Result(
      file: file,
      declined: true,
      top1: false,
      top3: false,
      brand: false,
      concentration: false,
      detail: ' — declined to guess',
    );
  }

  final keys = candidates
      .map((c) => buildFragranceKey(
            rawBrand: c['brand'] as String? ?? '',
            rawName: c['name'] as String? ?? '',
            rawConcentration: c['concentration'] as String?,
          ))
      .toList();

  final first = keys.first;
  return _Result(
    file: file,
    declined: false,
    top1: first == expected,
    top3: keys.contains(expected),
    brand: keys.any((k) => k.brand == expected.brand),
    // Judged only on the candidate that got the NAME right — otherwise a
    // scan that identified the wrong fragrance but happened to say "edp"
    // would count as a concentration hit.
    concentration: keys.any(
      (k) => k.brand == expected.brand &&
          k.name == expected.name &&
          k.concentration == expected.concentration,
    ),
    detail: first == expected ? '' : ' — got ${first.value}, want ${expected.value}',
  );
}

Future<Map<String, dynamic>> _identify({
  required HttpClient client,
  required String url,
  required String token,
  required List<int> bytes,
}) async {
  final request = await client.postUrl(Uri.parse('$url/functions/v1/identify'));
  request.headers
    ..set(HttpHeaders.contentTypeHeader, 'application/json')
    ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
  request.write(jsonEncode({
    'image': base64Encode(bytes),
    'mediaType': 'image/jpeg',
  }));

  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}: $text');
  }
  return jsonDecode(text) as Map<String, dynamic>;
}

// =============================================================================

void _report(List<_Result> results) {
  final total = results.length;
  if (total == 0) {
    stdout.writeln('\nNothing evaluated.');
    return;
  }

  final errored = results.where((r) => r.errored).length;
  final declined = results.where((r) => r.declined).length;
  // Accuracy is over ATTEMPTED scans. A decline is neither right nor wrong, and
  // folding it into the denominator would make refusing to guess look like a
  // failure — which would push the prompt toward exactly the confident
  // invention this project exists to avoid.
  final attempted = results.where((r) => !r.declined && !r.errored).toList();
  final n = attempted.length;

  String pct(int hits) =>
      n == 0 ? 'n/a' : '${(hits / n * 100).toStringAsFixed(1)}%';

  stdout
    ..writeln('\n${'=' * 60}')
    ..writeln('IDENTIFICATION ACCURACY')
    ..writeln('=' * 60)
    ..writeln('photographs        $total')
    ..writeln('errored            $errored')
    ..writeln('declined to guess  $declined  (not counted as wrong)')
    ..writeln('attempted          $n')
    ..writeln('')
    ..writeln('top-1              ${pct(attempted.where((r) => r.top1).length)}'
        '   the first candidate is the right catalog row')
    ..writeln('top-3              ${pct(attempted.where((r) => r.top3).length)}'
        '   the right row is in the shortlist  <- the number that matters')
    ..writeln('brand              ${pct(attempted.where((r) => r.brand).length)}'
        '   the house was right')
    ..writeln(
        'concentration      ${pct(attempted.where((r) => r.concentration).length)}'
        '   strength right on the right fragrance')
    ..writeln('')
    ..writeln('Graded through buildFragranceKey, so a different spelling of the')
    ..writeln('same fragrance counts as correct. top-3 is the UX number: the')
    ..writeln('confirm sheet shows a shortlist and the user picks.');

  final misses = attempted.where((r) => !r.top3).toList();
  if (misses.isNotEmpty) {
    stdout.writeln('\nMissed entirely (${misses.length}):');
    for (final miss in misses) {
      stdout.writeln('  ${miss.file}${miss.detail}');
    }
  }
}

// =============================================================================

class _Options {
  _Options({
    required this.url,
    required this.token,
    required this.manifestPath,
    required this.limit,
  });

  final String url;
  final String token;
  final String manifestPath;
  final int limit;
}

_Options? _parseArgs(List<String> args) {
  String? url;
  String? token;
  var manifest = 'eval/manifest.json';
  var limit = 1000;

  for (var i = 0; i < args.length - 1; i++) {
    switch (args[i]) {
      case '--url':
        url = args[i + 1].replaceAll(RegExp(r'/+$'), '');
      case '--token':
        token = args[i + 1];
      case '--manifest':
        manifest = args[i + 1];
      case '--limit':
        limit = int.tryParse(args[i + 1]) ?? limit;
    }
  }

  if (url == null || token == null) return null;
  return _Options(
    url: url,
    token: token,
    manifestPath: manifest,
    limit: limit,
  );
}
