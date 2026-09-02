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

/// The signed-in user's profile row.
final profileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  ref.watch(currentUserProvider);
  return ref.watch(repositoryProvider).loadProfile();
});

/// How many bottles have landed on the shelf since the user last looked at it.
///
/// Deliberately NOT persisted. It answers "did something happen while I was
/// looking elsewhere in this session", and a badge that survives a restart is
/// answering a different, staler question — the shelf itself is the record of
/// what you own.
///
/// Cleared by the Shelf screen when it appears, rather than by the tab that
/// navigates to it, so every route in (the tab, the empty-state button, a deep
/// link) clears it. One place, no way to miss a path.
class UnseenShelfCount extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state = state + 1;

  void clear() {
    if (state != 0) state = 0;
  }
}

final unseenShelfCountProvider =
    NotifierProvider<UnseenShelfCount, int>(UnseenShelfCount.new);

/// Below this many usable catalog rows, ask `suggest` for more names.
///
/// Once the catalog is real this never fires again, so the cold-start cost is
/// paid once across all users rather than per person.
const coldStartCatalogFloor = 40;

/// Hard cap on how many proposed candidates are resolved in one go.
///
/// Each miss against the catalog costs an `enrich` call, so this is the ceiling
/// on what one tap of Discover can spend. See the comment at the call site.
const coldStartResolveLimit = 8;

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
  if (pool.length < coldStartCatalogFloor) {
    try {
      final proposed = await scan.suggest(
        profileText: renderProfileForModel(profile, items),
        ownedNames: items.map((i) => i.fragrance.displayName).toList(),
      );

      // ---------------------------------------------------------------------
      // CONCURRENTLY, AND CAPPED. Both halves of that were learned by watching
      // the function log on a first run.
      //
      // This loop used to be sequential over 12 candidates, and each candidate
      // that misses the catalog costs an `enrich` call. The log showed
      // `suggest` followed by enrich after enrich roughly seven seconds apart:
      // about ninety seconds of spinner on a first open, and a dozen model
      // calls billed to whoever tapped Discover first.
      //
      // Awaiting them together turns that into roughly one round trip. The cap
      // bounds the worst case rather than trusting the model to be brief, and
      // it is deliberately smaller than what `suggest` may return — a pool of
      // this size is already plenty for the scoring to have something to rank.
      //
      // Nothing is lost by capping: the catalog is shared, so the next person
      // to want these rows finds them already there and pays nothing.
      // ---------------------------------------------------------------------
      final resolved = await Future.wait(
        proposed.take(coldStartResolveLimit).map((candidate) async {
          try {
            return await scan.resolveToCatalog(candidate);
          } catch (_) {
            // One bad candidate must not lose the other eleven.
            return null;
          }
        }),
      );

      for (final fragrance in resolved) {
        if (fragrance == null) continue;
        if (dismissed.contains(fragrance.id)) continue;
        if (pool.any((f) => f.id == fragrance.id)) continue;
        pool.add(fragrance);
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
