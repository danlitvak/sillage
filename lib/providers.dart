/// Riverpod wiring.
///
/// Riverpod because every screen here is an async request with loading, error
/// and data states, which is exactly what `AsyncValue` models — and because the
/// taste profile is derived from two other async values (the collection and a
/// catalog sample) and has to recompute when either changes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/models.dart';
import 'core/recommend.dart';
import 'core/taste.dart';
import 'data/repository.dart';
import 'data/scan_service.dart';

final supabaseProvider = Provider<SupabaseClient>((ref) => Supabase.instance.client);

final repositoryProvider = Provider<SillageRepository>(
  (ref) => SillageRepository(ref.watch(supabaseProvider)),
);

final scanServiceProvider = Provider<ScanService>(
  (ref) => ScanService(ref.watch(supabaseProvider), ref.watch(repositoryProvider)),
);

/// Auth state, as a stream so the router redirects the moment it changes.
final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

final currentUserProvider = Provider<User?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser;
});

/// The user's collection.
final collectionProvider = FutureProvider<List<CollectionItem>>((ref) async {
  ref.watch(currentUserProvider);
  return ref.watch(repositoryProvider).loadCollection();
});

/// A catalog sample, used both for IDF statistics and as a recommendation pool.
final catalogProvider = FutureProvider<List<Fragrance>>((ref) async {
  ref.watch(currentUserProvider);
  return ref.watch(repositoryProvider).loadCatalogSample();
});

/// Catalog-wide statistics.
///
/// Derived rather than stored, so it can never disagree with the catalog it was
/// computed from.
final catalogStatsProvider = Provider<AsyncValue<CatalogStats>>((ref) {
  return ref.watch(catalogProvider).whenData(CatalogStats.from);
});

/// The taste profile — the app's central derived value.
final tasteProfileProvider = Provider<AsyncValue<TasteProfile>>((ref) {
  final collection = ref.watch(collectionProvider);
  final stats = ref.watch(catalogStatsProvider);

  return collection.when(
    loading: () => const AsyncValue.loading(),
    error: AsyncValue.error,
    data: (items) => stats.when(
      loading: () => const AsyncValue.loading(),
      error: AsyncValue.error,
      data: (s) => AsyncValue.data(buildTasteProfile(items: items, stats: s)),
    ),
  );
});

/// Recommendations, grouped by strategy.
///
/// ---------------------------------------------------------------------------
/// THE COLD-START STEP
/// ---------------------------------------------------------------------------
/// The candidate pool is whatever the catalog already holds PLUS, when that is
/// thin, fragrances proposed by the `suggest` function. The model contributes
/// names; the scoring, ranking and every explanation shown to the user are
/// computed here from note vectors.
///
/// Proposed candidates are resolved through the same identity path as a scan,
/// so a suggestion and a scan of the same bottle land on one catalog row.
final recommendationsProvider =
    FutureProvider<Map<RecStrategy, List<Recommendation>>>((ref) async {
  final profile = ref.watch(tasteProfileProvider).valueOrNull;
  final items = ref.watch(collectionProvider).valueOrNull;
  final stats = ref.watch(catalogStatsProvider).valueOrNull;
  final catalog = ref.watch(catalogProvider).valueOrNull;

  if (profile == null || items == null || stats == null || catalog == null) {
    return const {};
  }
  // Recommendations on a shelf this small are noise dressed as insight.
  if (!profile.hasEnoughForPatterns) return const {};

  // Read every dependency BEFORE the first await. `ref.watch` after an
  // asynchronous gap can attach to a disposed provider container when the
  // collection changes mid-flight.
  final repo = ref.watch(repositoryProvider);
  final scan = ref.watch(scanServiceProvider);

  final dismissed = await repo.dismissedFragranceIds();

  var pool = catalog.where((f) => !dismissed.contains(f.id)).toList();

  // Ask for more names only when the catalog cannot support a real comparison.
  // The threshold is deliberately low: once the catalog is real, this stops
  // costing anything.
  if (pool.length < 40) {
    try {
      final proposed = await scan.suggest(
        profileText: renderProfileForModel(profile, items),
        ownedNames: items.map((i) => i.fragrance.displayName).toList(),
      );
      for (final candidate in proposed.take(12)) {
        final resolved = await scan.resolveToCatalog(candidate);
        if (!dismissed.contains(resolved.id)) pool.add(resolved);
      }
    } on ScanException {
      // A cold-start failure is not a screen-level error: whatever the catalog
      // already holds still produces real recommendations.
    }
  }

  return recommend(
    RecommendationInput(
      profile: profile,
      owned: items,
      candidates: pool,
      stats: stats,
    ),
  );
});

/// Renders a profile as the prose the `suggest` function reads.
///
/// Kept here rather than in `core/` because it is a wire format for one
/// endpoint, not part of the taste model. Deliberately states the DETECTED
/// PATTERNS rather than dumping the collection: what the pool needs to respect
/// is "mostly clones" and "nothing fresh", not a list of ninety notes.
String renderProfileForModel(TasteProfile profile, List<CollectionItem> items) {
  final buffer = StringBuffer()
    ..writeln('Collection size: ${profile.itemCount}');

  if (profile.patterns.isNotEmpty) {
    buffer.writeln('\nDetected patterns:');
    for (final p in profile.patterns) {
      buffer.writeln('- ${p.headline}: ${p.detail}');
    }
  }

  final houses = profile.houseCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (houses.isNotEmpty) {
    buffer.writeln('\nHouses owned:');
    for (final h in houses.take(10)) {
      buffer.writeln('- ${h.key} (${h.value})');
    }
  }

  final notes = profile.noteFrequency.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (notes.isNotEmpty) {
    buffer.writeln('\nMost common notes:');
    for (final n in notes.take(12)) {
      buffer.writeln('- ${n.key} (${(n.value * 100).round()}% of the shelf)');
    }
  }

  final clones = items.where((i) => i.fragrance.isClone).toList();
  if (clones.isNotEmpty) {
    buffer.writeln('\nOwned clones (propose the originals of these):');
    for (final c in clones.take(10)) {
      buffer.writeln('- ${c.fragrance.brand.displayName} ${c.fragrance.displayName}');
    }
  }

  return buffer.toString();
}
