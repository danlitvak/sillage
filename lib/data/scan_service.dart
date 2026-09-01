/// The identification pipeline: photo → candidates → confirmation → catalog.
///
/// =============================================================================
/// THE STEP THAT IS NOT AUTOMATED, AND WHY
/// =============================================================================
/// Nothing here writes to the catalog or the collection until a human has
/// confirmed a candidate. That is not caution for its own sake — it follows
/// from what the photo can actually support.
///
/// Houses reuse one bottle across a whole line, so a photograph frequently
/// narrows a fragrance to a LINE and no further. `identify` is asked for a
/// ranked shortlist precisely so that ambiguity survives to the UI instead of
/// being resolved by a coin flip, and the confirm sheet is where it gets
/// resolved by someone holding the bottle.
///
/// DESIGN.md: "nothing bad can happen with just one button click".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/identity.dart';
import '../core/models.dart';
import 'repository.dart';

/// One thing the photo might be.
class ScanCandidate {
  const ScanCandidate({
    required this.brand,
    required this.name,
    required this.concentration,
    required this.confidence,
    required this.reasoning,
  });

  final String brand;
  final String name;
  final Concentration concentration;

  /// 0..1, about THIS photograph rather than about the fragrance in general.
  final double confidence;

  /// One sentence naming what in the image supports this candidate.
  final String reasoning;

  /// The catalog key this candidate would resolve to.
  FragranceKey get key => buildFragranceKey(
        rawBrand: brand,
        rawName: name,
        rawConcentration: concentration.wire,
      );

  String get displayName => '$brand $name';

  factory ScanCandidate.fromJson(Map<String, dynamic> json) => ScanCandidate(
        brand: json['brand'] as String? ?? '',
        name: json['name'] as String? ?? '',
        concentration: Concentration.fromWire(json['concentration'] as String?),
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        reasoning: json['reasoning'] as String? ?? '',
      );
}

/// What one scan produced.
class ScanResult {
  const ScanResult({
    required this.candidates,
    required this.labelText,
    required this.legible,
    required this.raw,
  });

  final List<ScanCandidate> candidates;

  /// The text the model says it actually read. Shown on the confirm sheet as
  /// the EVIDENCE for the candidates, so the user can see whether the answer
  /// came from the label or from the bottle's silhouette.
  final String labelText;

  /// False when the model was working from shape and colour alone. The sheet
  /// says so, because a confident-looking candidate derived from a bottle
  /// outline deserves more scepticism than one read off the label.
  final bool legible;

  final Map<String, dynamic> raw;

  bool get isEmpty => candidates.isEmpty;
}

/// Raised when a function returns a mapped error. Carries the code so the UI
/// can say something specific instead of "something went wrong".
class ScanException implements Exception {
  ScanException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;

  /// Whether retrying the same request could plausibly work.
  bool get isRetryable =>
      code == 'rate_limited' || code == 'upstream_unreachable' || code == 'upstream_failed';
}

class ScanService {
  ScanService(this._client, this._repo);

  final SupabaseClient _client;
  final SillageRepository _repo;

  /// Photo in, ranked candidates out. Writes nothing.
  Future<ScanResult> identify(Uint8List imageBytes, {String? hint}) async {
    final response = await _invoke('identify', {
      'image': base64Encode(imageBytes),
      'mediaType': 'image/jpeg',
      'hint': ?hint,
    });

    final candidates = (response['candidates'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ScanCandidate.fromJson)
        .where((c) => c.brand.isNotEmpty && c.name.isNotEmpty)
        .toList();

    return ScanResult(
      candidates: candidates,
      labelText: response['label_text'] as String? ?? '',
      legible: response['legible'] as bool? ?? false,
      raw: (response['raw'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  /// Resolves a confirmed candidate to a catalog row, creating it if new.
  ///
  /// ---------------------------------------------------------------------
  /// THE CACHE CHECK IS THE WHOLE ECONOMICS OF THIS APP
  /// ---------------------------------------------------------------------
  /// `findByKey` first. A fragrance already in the catalog costs one SELECT —
  /// no model call at all — which is why the second person to scan a bottle of
  /// Sauvage pays nothing and gets the better, possibly human-corrected,
  /// pyramid rather than a fresh guess.
  ///
  /// It is also why the identity key in `identity.dart` had to be right before
  /// any of this was written: a key that forks re-enriches the same fragrance
  /// forever and never accumulates a correction.
  Future<Fragrance> resolveToCatalog(ScanCandidate candidate) async {
    final key = candidate.key;

    final existing = await _repo.findByKey(key);
    // Only reuse a row that already has a pyramid. A row created by an earlier
    // scan the model could not enrich is worth retrying rather than serving
    // forever as an empty shell.
    if (existing != null && existing.notes.isNotEmpty) return existing;

    final enriched = await _enrich(candidate);

    final id = await _repo.proposeFragrance(
      key: key,
      brandDisplay: candidate.brand,
      displayName: candidate.name,
      brandTier: BrandTier.unknown,
      // Everything the model produced is stamped `model`, so the UI marks it
      // unverified and a later human correction outranks it permanently.
      source: Provenance.model,
      releaseYear: enriched?.releaseYear,
      perfumer: enriched?.perfumer,
      notes: enriched?.notes ?? const [],
      accords: enriched?.accords ?? const [],
    );

    final saved = await _repo.findByKey(key);
    if (saved != null) return saved;

    // The row was written but could not be read back — a transient read
    // failure, not a reason to lose the user's scan. A minimal in-memory
    // fragrance keeps the flow alive; the next load picks up the real row.
    return Fragrance(
      id: id,
      key: key,
      displayName: candidate.name,
      brand: Brand(key: key.brand, displayName: candidate.brand),
    );
  }

  /// Fetches a pyramid, or null when the model admits it does not know.
  ///
  /// A null here is a NORMAL outcome, not an error: the fragrance still enters
  /// the catalog and the collection, just with an empty pyramid the user can
  /// fill in. That is the honest failure mode, and it is far better than the
  /// alternative — a fluent, specific, invented pyramid that a fragrance person
  /// spots immediately and that silently corrupts every recommendation
  /// computed from it.
  Future<_Enriched?> _enrich(ScanCandidate candidate) async {
    try {
      final response = await _invoke('enrich', {
        'brand': candidate.brand,
        'name': candidate.name,
        'concentration': candidate.concentration.wire,
      });

      if (response['known'] != true) return null;

      final notes = (response['notes'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((n) => {
                'key': n['key'],
                'display_name': n['display_name'],
                'tier': n['tier'],
                'position': n['position'],
                'family': n['family'],
              })
          .toList();

      final accords = (response['accords'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((a) => {
                'key': a['key'],
                'display_name': a['display_name'],
                'weight': a['weight'],
              })
          .toList();

      return _Enriched(
        releaseYear: (response['release_year'] as num?)?.toInt(),
        perfumer: response['perfumer'] as String?,
        notes: notes,
        accords: accords,
      );
    } on ScanException {
      // Enrichment is best-effort. Losing the pyramid is a smaller loss than
      // losing the whole scan, and the fragrance can be enriched later.
      return null;
    }
  }

  /// Asks for a candidate pool given a rendered taste profile.
  ///
  /// The model names fragrances; it does not rank them. Scoring and every word
  /// of the explanation the user reads happen in `lib/core/recommend.dart`.
  Future<List<ScanCandidate>> suggest({
    required String profileText,
    required List<String> ownedNames,
  }) async {
    final response = await _invoke('suggest', {
      'profile': profileText,
      'owned': ownedNames,
    });
    return (response['candidates'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ScanCandidate.fromJson)
        .where((c) => c.brand.isNotEmpty && c.name.isNotEmpty)
        .toList();
  }

  /// Calls an Edge Function and turns a mapped error into a [ScanException].
  Future<Map<String, dynamic>> _invoke(
    String name,
    Map<String, dynamic> body,
  ) async {
    try {
      final res = await _client.functions.invoke(name, body: body);
      final data = res.data;
      if (data is! Map) {
        throw ScanException('bad_response', 'The server sent something unexpected.');
      }
      final map = data.cast<String, dynamic>();
      if (map['error'] != null) {
        throw ScanException(
          map['error'] as String,
          map['detail'] as String? ?? _messageFor(map['error'] as String),
        );
      }
      return map;
    } on FunctionException catch (e) {
      final details = e.details;
      final code = details is Map ? details['error'] as String? : null;
      throw ScanException(code ?? 'failed', _messageFor(code ?? 'failed'));
    }
  }

  /// One sentence per failure, written for someone holding a bottle in a shop
  /// rather than for a log. Each says what to do next.
  String _messageFor(String code) => switch (code) {
        'rate_limited' => 'Too many scans in a row. Wait a minute and try again.',
        'not_configured' =>
          'Scanning is not set up on the server yet. Add the bottle by hand.',
        'key_invalid' =>
          'AI credentials are expired. Add the bottle by hand for now.',
        'upstream_unreachable' => 'Could not reach the server. Check your connection.',
        'refused' => 'The model would not process that image. Try another photo.',
        'truncated' => 'The response was cut off. Try again.',
        'image_too_large' => 'That photo is too large. Try again.',
        'unauthorized' => 'You are signed out. Sign in and try again.',
        _ => 'Identification failed. You can still add the bottle by hand.',
      };
}

class _Enriched {
  const _Enriched({
    required this.releaseYear,
    required this.perfumer,
    required this.notes,
    required this.accords,
  });

  final int? releaseYear;
  final String? perfumer;
  final List<Map<String, dynamic>> notes;
  final List<Map<String, dynamic>> accords;
}
