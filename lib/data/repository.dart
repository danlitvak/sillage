/// Supabase access, and the conversion between database rows and the pure
/// domain models in `lib/core/`.
///
/// Everything that knows about Postgres lives here. `lib/core/` never imports
/// Supabase, which is what keeps the taste and recommendation layer testable
/// with no network and no device.
library;

import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/identity.dart';
import '../core/models.dart';

/// The columns needed to build a [Fragrance], as one PostgREST select.
///
/// Written once and reused, because a fragrance assembled from a different set
/// of columns in a different place is how two screens end up disagreeing about
/// whether a pyramid is verified.
const _fragranceSelect = '''
  id, key, name_key, concentration, display_name, release_year, perfumer,
  notes_source,
  brand:brands ( key, display_name, tier ),
  fragrance_notes ( tier, position, note:notes ( key, display_name, family ) ),
  fragrance_accords ( weight, accord:accords ( key, display_name ) ),
  clone_of!clone_of_clone_id_fkey ( original_id )
''';

class SillageRepository {
  SillageRepository(this._client);

  final SupabaseClient _client;

  String? get userId => _client.auth.currentUser?.id;

  // ===========================================================================
  // READS
  // ===========================================================================

  /// The signed-in user's collection.
  Future<List<CollectionItem>> loadCollection() async {
    final rows = await _client
        .from('collection_items')
        .select('''
          id, status, photo_path, bottle_ml, acquired_on, rating, note,
          fragrance:fragrances ( $_fragranceSelect )
        ''')
        .order('created_at', ascending: false);

    return rows
        .map(_collectionItemFromRow)
        .whereType<CollectionItem>()
        .toList(growable: false);
  }

  /// A slice of the catalog, for IDF statistics and as a recommendation pool.
  ///
  /// Bounded: the IDF weighting needs a representative sample, not the whole
  /// table, and on a phone the whole table is not something to hold in memory.
  /// The bound is stated rather than assumed — see the note in `CatalogStats`.
  Future<List<Fragrance>> loadCatalogSample({int limit = 600}) async {
    final rows = await _client
        .from('fragrances')
        .select(_fragranceSelect)
        .limit(limit);
    return rows.map(_fragranceFromRow).whereType<Fragrance>().toList();
  }

  /// Looks up one fragrance by its catalog key, or null if the catalog has
  /// never seen it. The cache check that makes `enrich` run at most once per
  /// fragrance.
  Future<Fragrance?> findByKey(FragranceKey key) async {
    final rows = await _client
        .from('fragrances')
        .select(_fragranceSelect)
        .eq('key', key.value)
        .limit(1);
    if (rows.isEmpty) return null;
    return _fragranceFromRow(rows.first);
  }

  /// Catalog rows whose key differs from [key] only by a gender marker.
  ///
  /// Offered on the confirm sheet so a near-duplicate is caught by a human
  /// before it forks the catalog — the counterpart to NOT stripping gendering
  /// in `identity.dart`.
  Future<List<Fragrance>> findGenderVariants(FragranceKey key) async {
    final rows = await _client
        .from('fragrances')
        .select(_fragranceSelect)
        .eq('concentration', key.concentration.wire)
        .limit(50);
    return rows
        .map(_fragranceFromRow)
        .whereType<Fragrance>()
        .where((f) => genderVariantOf(f.key, key))
        .toList();
  }

  // ===========================================================================
  // WRITES
  // ===========================================================================

  /// Proposes a fragrance into the shared catalog and returns its id.
  ///
  /// Goes through the SECURITY DEFINER function rather than an INSERT, so the
  /// upsert is atomic, the proposer is recorded, and a model pass cannot
  /// overwrite a human's correction. See `20260831120100_catalog_writes.sql`.
  Future<String> proposeFragrance({
    required FragranceKey key,
    required String brandDisplay,
    required String displayName,
    required BrandTier brandTier,
    required Provenance source,
    int? releaseYear,
    String? perfumer,
    List<Map<String, dynamic>> notes = const [],
    List<Map<String, dynamic>> accords = const [],
  }) async {
    final id = await _client.rpc<String>(
      'catalog_propose_fragrance',
      params: {
        'p_brand_key': key.brand,
        'p_brand_display': brandDisplay,
        'p_brand_tier': brandTier.wire,
        'p_fragrance_key': key.value,
        'p_name_key': key.name,
        'p_display_name': displayName,
        'p_concentration': key.concentration.wire,
        'p_release_year': releaseYear,
        'p_perfumer': perfumer,
        'p_notes': notes,
        'p_accords': accords,
        'p_source': source.wire,
      },
    );
    return id;
  }

  Future<void> addToCollection({
    required String fragranceId,
    OwnershipStatus status = OwnershipStatus.have,
    String? photoPath,
    int? bottleMl,
    double? rating,
    String? note,
  }) async {
    final uid = userId;
    if (uid == null) throw StateError('not signed in');
    await _client.from('collection_items').upsert({
      'user_id': uid,
      'fragrance_id': fragranceId,
      'status': status.wire,
      'photo_path': ?photoPath,
      'bottle_ml': ?bottleMl,
      'rating': ?rating,
      'note': ?note,
    }, onConflict: 'user_id,fragrance_id');
  }

  Future<void> updateCollectionItem(
    String id, {
    OwnershipStatus? status,
    double? rating,
    int? bottleMl,
    String? note,
  }) async {
    await _client.from('collection_items').update({
      if (status != null) 'status': status.wire,
      'rating': ?rating,
      'bottle_ml': ?bottleMl,
      'note': ?note,
    }).eq('id', id);
  }

  Future<void> removeFromCollection(String id) async {
    await _client.from('collection_items').delete().eq('id', id);
  }

  /// Records one identification attempt, whatever its outcome.
  ///
  /// [rawResponse] is stored verbatim. When an identification turns out wrong,
  /// this is the difference between seeing exactly what the model said and a
  /// mystery — and a scan the user REJECTED is the most interesting row in the
  /// table, so it is written too.
  Future<void> recordScan({
    String? photoPath,
    String? labelText,
    Map<String, dynamic>? rawResponse,
    String? chosenFragranceId,
    bool rejected = false,
  }) async {
    final uid = userId;
    if (uid == null) return;
    await _client.from('scans').insert({
      'user_id': uid,
      'photo_path': photoPath,
      'label_text': labelText,
      'raw_response': rawResponse,
      'chosen_fragrance_id': chosenFragranceId,
      'rejected': rejected,
    });
  }

  Future<void> recordRecommendationFeedback({
    required String fragranceId,
    required String strategy,
    required String verdict,
  }) async {
    final uid = userId;
    if (uid == null) return;
    await _client.from('recommendation_feedback').upsert({
      'user_id': uid,
      'fragrance_id': fragranceId,
      'strategy': strategy,
      'verdict': verdict,
    }, onConflict: 'user_id,fragrance_id,strategy');
  }

  /// Fragrance ids the user has already dismissed, so a rejected suggestion
  /// does not come back next time.
  Future<Set<String>> dismissedFragranceIds() async {
    final rows = await _client
        .from('recommendation_feedback')
        .select('fragrance_id')
        .eq('verdict', 'dismissed');
    return rows.map((r) => r['fragrance_id'] as String).toSet();
  }

  // ===========================================================================
  // STORAGE
  // ===========================================================================

  static const bottlePhotoBucket = 'bottle-photos';

  /// Uploads a bottle photo into the user's own folder.
  ///
  /// The path is prefixed with the user id because the bucket's RLS policy
  /// keys on the first path segment — a photo written anywhere else is
  /// rejected, which is deliberate.
  Future<String> uploadBottlePhoto({
    required String fileName,
    required List<int> bytes,
  }) async {
    final uid = userId;
    if (uid == null) throw StateError('not signed in');
    final path = '$uid/$fileName';
    await _client.storage.from(bottlePhotoBucket).uploadBinary(
          path,
          _asBytes(bytes),
          fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
        );
    return path;
  }

  String publicPhotoUrl(String path) =>
      _client.storage.from(bottlePhotoBucket).getPublicUrl(path);

  // ===========================================================================
  // ROW -> MODEL
  // ===========================================================================

  CollectionItem? _collectionItemFromRow(Map<String, dynamic> row) {
    final fragranceRow = row['fragrance'];
    if (fragranceRow is! Map<String, dynamic>) return null;
    final fragrance = _fragranceFromRow(fragranceRow);
    if (fragrance == null) return null;

    return CollectionItem(
      id: row['id'] as String,
      fragrance: fragrance,
      status: OwnershipStatus.fromWire(row['status'] as String?),
      rating: (row['rating'] as num?)?.toDouble(),
      photoPath: row['photo_path'] as String?,
      bottleMl: row['bottle_ml'] as int?,
      acquiredOn: row['acquired_on'] == null
          ? null
          : DateTime.tryParse(row['acquired_on'] as String),
      note: row['note'] as String?,
    );
  }

  Fragrance? _fragranceFromRow(Map<String, dynamic> row) {
    final brandRow = row['brand'];
    if (brandRow is! Map<String, dynamic>) return null;

    final notes = <NoteRef>[];
    for (final n in (row['fragrance_notes'] as List? ?? const [])) {
      if (n is! Map<String, dynamic>) continue;
      final note = n['note'];
      if (note is! Map<String, dynamic>) continue;
      notes.add(NoteRef(
        key: note['key'] as String,
        displayName: note['display_name'] as String? ?? note['key'] as String,
        tier: NoteTier.fromWire(n['tier'] as String?),
        position: (n['position'] as num?)?.toInt() ?? 0,
        family: note['family'] as String?,
      ));
    }

    final accords = <AccordRef>[];
    for (final a in (row['fragrance_accords'] as List? ?? const [])) {
      if (a is! Map<String, dynamic>) continue;
      final accord = a['accord'];
      if (accord is! Map<String, dynamic>) continue;
      accords.add(AccordRef(
        key: accord['key'] as String,
        displayName: accord['display_name'] as String? ?? accord['key'] as String,
        weight: (a['weight'] as num?)?.toDouble() ?? 1.0,
      ));
    }

    // A fragrance can be a dupe of more than one original in principle; the UI
    // only ever shows one, so the first is taken and the rest are reachable
    // from the detail screen's own query.
    String? cloneOfId;
    final cloneRows = row['clone_of'];
    if (cloneRows is List && cloneRows.isNotEmpty) {
      final first = cloneRows.first;
      if (first is Map<String, dynamic>) {
        cloneOfId = first['original_id'] as String?;
      }
    }

    return Fragrance(
      id: row['id'] as String,
      key: FragranceKey(
        brand: brandRow['key'] as String,
        name: row['name_key'] as String,
        concentration: Concentration.fromWire(row['concentration'] as String?),
      ),
      displayName: row['display_name'] as String,
      brand: Brand(
        key: brandRow['key'] as String,
        displayName: brandRow['display_name'] as String? ?? brandRow['key'] as String,
        tier: BrandTier.fromWire(brandRow['tier'] as String?),
      ),
      notes: notes,
      accords: accords,
      releaseYear: (row['release_year'] as num?)?.toInt(),
      perfumer: row['perfumer'] as String?,
      cloneOfId: cloneOfId,
      notesSource: Provenance.fromWire(row['notes_source'] as String?),
    );
  }
}

/// Adapts a `List<int>` to the `Uint8List` the storage client wants, without
/// copying when it already is one.
Uint8List _asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
