/// Supabase access.
///
/// Everything that knows about Postgres lives here or in `mapping.dart`.
/// `lib/core/` never imports Supabase, which is what keeps the taste and
/// recommendation layer testable with no network and no device.
library;

import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/identity.dart';
import '../core/models.dart';
import 'mapping.dart';

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
        .map(collectionItemFromRow)
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
    return rows.map(fragranceFromRow).whereType<Fragrance>().toList();
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
    return fragranceFromRow(rows.first);
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
        .map(fragranceFromRow)
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
  // PROFILE
  // ===========================================================================

  /// The signed-in user's profile row, created by the `handle_new_user`
  /// trigger at sign-up. Null only if that trigger has not run yet.
  Future<Map<String, dynamic>?> loadProfile() async {
    final uid = userId;
    if (uid == null) return null;
    final rows =
        await _client.from('profiles').select('id, display_name, created_at')
            .eq('id', uid).limit(1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> updateDisplayName(String? name) async {
    final uid = userId;
    if (uid == null) throw StateError('not signed in');
    final trimmed = name?.trim();
    await _client.from('profiles').update({
      // Empty is stored as null, not as "", so "has the user named themselves"
      // is one check rather than two.
      'display_name': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
    }).eq('id', uid);
  }

  String? get email => _client.auth.currentUser?.email;

  Future<void> signOut() => _client.auth.signOut();

  // ---------------------------------------------------------------------------
  // SHARING
  // ---------------------------------------------------------------------------
  // All three go through SECURITY DEFINER functions rather than table access.
  // See 20260902060000_shelf_sharing.sql for why the whole feature is one
  // function instead of a set of policies.

  /// Turns sharing on and returns the new slug.
  ///
  /// Always mints a NEW one, so re-enabling does not resurrect a link that was
  /// previously revoked.
  Future<String> shareShelf() => _client.rpc<String>('share_shelf');

  Future<void> unshareShelf() => _client.rpc<void>('unshare_shelf');

  /// The current slug, or null when sharing is off.
  Future<String?> currentShareSlug() async {
    final uid = userId;
    if (uid == null) return null;
    final rows =
        await _client.from('profiles').select('share_slug').eq('id', uid).limit(1);
    return rows.isEmpty ? null : rows.first['share_slug'] as String?;
  }

  /// Reads someone else's shared shelf. Works signed out — that is the point.
  ///
  /// Returns null for a slug that never existed OR was revoked; the function
  /// deliberately cannot tell those apart.
  Future<Map<String, dynamic>?> loadSharedShelf(String slug) async {
    final data = await _client.rpc<dynamic>(
      'get_shared_shelf',
      params: {'p_slug': slug},
    );
    return data is Map ? data.cast<String, dynamic>() : null;
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

}

/// Adapts a `List<int>` to the `Uint8List` the storage client wants, without
/// copying when it already is one.
Uint8List _asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
