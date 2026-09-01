/// Database rows to domain models.
///
/// Split out of `repository.dart` so it imports NOTHING but `core/` — no
/// Supabase, no Flutter. Two things follow:
///
///   * the parsing is unit-testable on its own, and
///   * a plain Dart script can read the same rows through the same code the app
///     uses, which is how `tool/check_recommender.dart` verifies the live stack
///     without a GUI.
///
/// A row that cannot be mapped returns null rather than throwing. One malformed
/// fragrance should cost that fragrance, not the whole shelf.
library;

import '../core/identity.dart';
import '../core/models.dart';

CollectionItem? collectionItemFromRow(Map<String, dynamic> row) {
  final fragranceRow = row['fragrance'];
  if (fragranceRow is! Map<String, dynamic>) return null;
  final fragrance = fragranceFromRow(fragranceRow);
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

Fragrance? fragranceFromRow(Map<String, dynamic> row) {
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
