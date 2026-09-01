/// The three recommendation strategies.
///
/// =============================================================================
/// EVERY RECOMMENDATION CARRIES THE REASON IT EXISTS
/// =============================================================================
/// A [Recommendation] cannot be constructed without an explanation, and every
/// explanation is built from figures this file computed rather than from a
/// sentence a model wrote. That is the whole design: the model supplies the
/// CANDIDATE POOL (it knows what fragrances exist), and this file decides which
/// of them to show and why.
///
/// The practical consequence is that "why am I being shown this" is always
/// answerable, and always true. A recommender that asks a model to both pick and
/// justify produces a fluent paragraph that cannot be checked against anything.
library;

import 'models.dart';
import 'taste.dart';

/// Which strategy produced a recommendation.
///
/// Recorded against feedback, so a strategy that only ever gets dismissed shows
/// up as such instead of being averaged into the others.
enum RecStrategy {
  /// Nearest to the collection centroid in note space.
  neighbour('neighbour'),

  /// Fills an accord the collection is missing.
  gap('gap'),

  /// Driven by a detected pattern — the clone's original, the house's other
  /// releases, the note being chased.
  pattern('pattern');

  const RecStrategy(this.wire);
  final String wire;

  String get label => switch (this) {
    RecStrategy.neighbour => 'Close to what you like',
    RecStrategy.gap => 'Fills a gap',
    RecStrategy.pattern => 'Because of how you buy',
  };
}

class Recommendation {
  const Recommendation({
    required this.fragrance,
    required this.strategy,
    required this.score,
    required this.explanation,
    this.drivingNotes = const [],
    this.relatedFragranceId,
  });

  final Fragrance fragrance;
  final RecStrategy strategy;

  /// 0..1 within its own strategy. NOT comparable across strategies — a 0.6
  /// cosine and a 0.6 gap score measure different things, which is why the
  /// Discover screen groups by strategy rather than merging into one ranked
  /// list.
  final double score;

  /// Why this, in a sentence built from computed figures.
  final String explanation;

  /// The notes that actually drove the score, heaviest first. What the UI
  /// shows under the explanation, and the reason the explanation is checkable.
  final List<String> drivingNotes;

  /// The fragrance this recommendation refers to — the original, for a clone
  /// pattern. Lets the UI link to it.
  final String? relatedFragranceId;
}

/// Everything the strategies need, gathered once.
class RecommendationInput {
  const RecommendationInput({
    required this.profile,
    required this.owned,
    required this.candidates,
    required this.stats,
  });

  final TasteProfile profile;
  final List<CollectionItem> owned;

  /// The pool to choose from. Supplied by the `suggest` Edge Function plus
  /// whatever the catalog already holds — see the cold-start note in the plan.
  final List<Fragrance> candidates;

  final CatalogStats stats;
}

/// Runs all three strategies and returns them grouped, best first within each.
///
/// [perStrategy] caps each group. Anything dropped is dropped visibly — the
/// Discover screen says how many more there were rather than silently truncating,
/// because a capped list that looks complete is worse than a short one.
Map<RecStrategy, List<Recommendation>> recommend(
  RecommendationInput input, {
  int perStrategy = 5,
}) {
  final owned = _ownedFragranceIds(input.owned);
  final pool = input.candidates
      .where((f) => !owned.contains(f.id))
      .toList(growable: false);

  return {
    RecStrategy.neighbour: _neighbour(input, pool).take(perStrategy).toList(),
    RecStrategy.gap: _gap(input, pool).take(perStrategy).toList(),
    RecStrategy.pattern: _pattern(input, pool).take(perStrategy).toList(),
  };
}

Set<String> _ownedFragranceIds(List<CollectionItem> items) => items
    // A `want` still counts as "do not recommend this" — the user has already
    // found it. It just does not shape the taste profile.
    .map((i) => i.fragrance.id)
    .toSet();

// =============================================================================
// STRATEGY 1 — NEIGHBOUR
// =============================================================================

/// Nearest to the collection centroid, by cosine over the IDF-weighted note
/// vectors.
///
/// Deliberately the least clever of the three. It answers "more of what you
/// already like", which is the right answer often enough to be the default, and
/// its explanation is the strongest of the three because the driving notes fall
/// straight out of the arithmetic.
List<Recommendation> _neighbour(
  RecommendationInput input,
  List<Fragrance> pool,
) {
  final centroid = input.profile.centroid;
  if (centroid.isEmpty) return const [];

  final out = <Recommendation>[];
  for (final f in pool) {
    final v = fragranceVector(f, input.stats);
    if (v.isEmpty) continue;
    final score = centroid.cosine(v);
    if (score <= 0) continue;

    // The notes doing the work: present in both, ranked by their contribution
    // to the dot product. This is the explanation, not a decoration of it.
    final shared = _sharedNotes(centroid, v, f);
    if (shared.isEmpty) continue;

    out.add(Recommendation(
      fragrance: f,
      strategy: RecStrategy.neighbour,
      score: score,
      explanation:
          'Shares ${_list(shared.take(3).map((e) => e.$2).toList())} with what '
          'you already wear.',
      drivingNotes: shared.map((e) => e.$2).toList(),
    ));
  }

  out.sort((a, b) => b.score.compareTo(a.score));
  return out;
}

/// Notes present in both vectors, ranked by contribution to the similarity.
List<(String, String)> _sharedNotes(
  NoteVector centroid,
  NoteVector candidate,
  Fragrance f,
) {
  final a = centroid.normalised().weights;
  final b = candidate.normalised().weights;
  final contributions = <String, double>{};
  for (final e in b.entries) {
    final o = a[e.key];
    if (o != null) contributions[e.key] = e.value * o;
  }
  final ranked = contributions.entries.toList()
    ..sort((x, y) => y.value.compareTo(x.value));

  final displayByKey = {for (final n in f.notes) n.key: n.displayName};
  return ranked
      .take(5)
      .map((e) => (e.key, displayByKey[e.key] ?? e.key))
      .toList();
}

// =============================================================================
// STRATEGY 2 — GAP
// =============================================================================

/// Best candidate in an accord the collection is short on.
///
/// Scored on how big the gap is AND how strongly the candidate carries the
/// missing accord — a token cedar note in an otherwise sweet fragrance does not
/// fill a woody gap, and scoring on the gap alone would let it.
List<Recommendation> _gap(RecommendationInput input, List<Fragrance> pool) {
  final gaps = input.profile.patterns
      .where((p) => p.kind == PatternKind.accordGap && p.subjectKey != null)
      .toList();
  if (gaps.isEmpty) return const [];

  final out = <Recommendation>[];
  for (final gap in gaps) {
    final accordKey = gap.subjectKey!;
    final catalogShare = (gap.evidence['catalogShare'] ?? 0).toDouble();
    final mine = (gap.evidence['mine'] ?? 0).toDouble();
    // 0..1: how absent this accord is from the shelf, relative to how common it
    // is in the catalog.
    final gapSize = catalogShare <= 0
        ? 0.0
        : ((catalogShare - mine) / catalogShare).clamp(0.0, 1.0);

    for (final f in pool) {
      final match = f.accords.where((a) => a.key == accordKey).firstOrNull;
      if (match == null) continue;

      // Both factors, multiplied: a big gap filled weakly and a small gap
      // filled strongly both score middling, which is the honest ordering.
      final score = (gapSize * match.weight).clamp(0.0, 1.0);
      if (score <= 0) continue;

      final display = match.displayName;
      out.add(Recommendation(
        fragrance: f,
        strategy: RecStrategy.gap,
        score: score,
        explanation:
            'You own almost nothing $display — this is '
            '${(match.weight * 100).round()}% $display.',
        drivingNotes: f.notes
            .where((n) => n.family == accordKey)
            .map((n) => n.displayName)
            .take(3)
            .toList(),
      ));
    }
  }

  out.sort((a, b) => b.score.compareTo(a.score));
  return _dedupeByFragrance(out);
}

// =============================================================================
// STRATEGY 3 — PATTERN
// =============================================================================

/// Recommendations that exist BECAUSE of how the collection was assembled.
///
/// The distinctive strategy, and the one the app was described by: it answers
/// "you buy clones — here is the original", "five from this house — here are the
/// two you are missing", "you keep chasing this note".
List<Recommendation> _pattern(RecommendationInput input, List<Fragrance> pool) {
  final out = <Recommendation>[];
  final byId = {for (final f in pool) f.id: f};

  // --- you own a clone → here is the original ------------------------------
  //
  // Runs on the OWNED CLONE EDGES directly, NOT gated on the clone-buyer
  // detector, and that distinction was got wrong the first time.
  //
  // Gating it on the pattern meant a shelf of 2 clones in 7 produced no
  // "here's the original" at all, because clone-buyer needs a strict majority.
  // But those are two different questions: the DETECTOR describes a collection
  // ("you mostly buy dupes"), while this RECOMMENDATION rests on a specific
  // recorded relationship between two bottles. Owning one clone makes its
  // original the single most relevant thing to suggest, whatever the rest of
  // the shelf looks like — and this is the app's most distinctive suggestion,
  // so hiding it behind a majority threshold made it unreachable for most
  // real collections.
  final cloneBuyer = input.profile.patterns
      .where((p) => p.kind == PatternKind.cloneBuyer)
      .firstOrNull;

  for (final item in input.owned) {
    final originalId = item.fragrance.cloneOfId;
    if (originalId == null) continue;
    final original = byId[originalId];
    if (original == null) continue;

    // The dominant-pattern evidence sharpens the sentence when it exists, but
    // the recommendation stands without it.
    final tail = cloneBuyer == null
        ? ''
        : ' ${cloneBuyer.evidence['clones']} of your '
            '${cloneBuyer.evidence['total']} bottles are dupes.';

    out.add(Recommendation(
      fragrance: original,
      strategy: RecStrategy.pattern,
      // The highest score the app produces, and the only one that is not an
      // estimate: this is a recorded relationship, not a similarity.
      score: 0.95,
      explanation:
          'You own ${item.fragrance.displayName}, a dupe of this.$tail',
      relatedFragranceId: item.fragrance.id,
    ));
  }

  for (final pattern in input.profile.patterns) {
    switch (pattern.kind) {
      // Handled above, on the edges themselves rather than on the detector.
      case PatternKind.cloneBuyer:
        break;

      // --- loyal to a house → its releases you do not have ----------------
      case PatternKind.houseLoyalist:
        final houseKey = pattern.subjectKey;
        if (houseKey == null) break;
        for (final f in pool.where((f) => f.brand.key == houseKey)) {
          out.add(Recommendation(
            fragrance: f,
            strategy: RecStrategy.pattern,
            score: 0.8,
            explanation:
                '${pattern.evidence['count']} of your '
                '${pattern.evidence['total']} bottles are '
                '${f.brand.displayName}. You do not have this one.',
          ));
        }

      // --- chasing a note → things that lead with it ----------------------
      case PatternKind.noteObsession:
        final noteKey = pattern.subjectKey;
        if (noteKey == null) break;
        for (final f in pool) {
          final note = f.notes.where((n) => n.key == noteKey).firstOrNull;
          if (note == null) continue;
          // Only when the note is prominent — a base-note anchor rather than a
          // top-note flicker. Otherwise "you like vanilla" recommends every
          // fragrance with a trace of it.
          if (note.tier == NoteTier.top) continue;
          out.add(Recommendation(
            fragrance: f,
            strategy: RecStrategy.pattern,
            score: 0.7 * note.intrinsicWeight,
            explanation:
                '${note.displayName} is in '
                '${((pattern.evidence['share'] ?? 0) * 100).round()}% of your '
                'shelf, and it is a ${note.tier.name} note here.',
            drivingNotes: [note.displayName],
          ));
        }

      case PatternKind.accordGap:
      case PatternKind.tierConcentration:
      case PatternKind.unverifiedData:
        // accordGap is served by the gap strategy; the other two describe the
        // collection rather than implying a purchase.
        break;
    }
  }

  out.sort((a, b) => b.score.compareTo(a.score));
  return _dedupeByFragrance(out);
}

// =============================================================================

/// Keeps the highest-scoring recommendation per fragrance.
///
/// A candidate can qualify twice — the house you are loyal to also making the
/// vanilla you chase — and showing it twice in one list reads as a bug.
List<Recommendation> _dedupeByFragrance(List<Recommendation> recs) {
  final seen = <String>{};
  final out = <Recommendation>[];
  for (final r in recs) {
    if (seen.add(r.fragrance.id)) out.add(r);
  }
  return out;
}

/// "a, b and c" — an Oxford-comma-free list for an explanation sentence.
String _list(List<String> items) {
  if (items.isEmpty) return '';
  if (items.length == 1) return items.first;
  if (items.length == 2) return '${items[0]} and ${items[1]}';
  return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}
