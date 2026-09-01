/// The taste layer: turning a collection into a profile you can reason about.
///
/// =============================================================================
/// THE DIVISION OF LABOUR THIS FILE EXISTS TO ENFORCE
/// =============================================================================
/// The model proposes CANDIDATES. This file decides and explains. Nothing here
/// calls an API, reads a database, or touches Flutter — every function is a pure
/// transformation of an in-memory collection, so every number the app shows a
/// user can be reproduced in a test with a hand-computed expected value.
///
/// That split is not tidiness. A recommender that asks a model "what should he
/// buy next" produces a plausible sentence and no way to check it. One that
/// computes a cosine over a note vocabulary and prints the notes that drove the
/// score produces an explanation that is true by construction.
library;

import 'dart:math' as math;

import 'models.dart';

// =============================================================================
// VECTORS
// =============================================================================

/// A sparse note vector: note key → weight.
///
/// Always non-negative. [normalised] returns the unit-length form, which is what
/// [cosine] expects — comparing unnormalised vectors would rank a fragrance with
/// twenty listed notes above a better match with eight, purely for having a
/// longer ingredient list.
class NoteVector {
  const NoteVector(this.weights);

  final Map<String, double> weights;

  static const NoteVector empty = NoteVector({});

  bool get isEmpty => weights.isEmpty;

  double get magnitude {
    var sum = 0.0;
    for (final w in weights.values) {
      sum += w * w;
    }
    return math.sqrt(sum);
  }

  NoteVector normalised() {
    final m = magnitude;
    if (m == 0) return NoteVector.empty;
    return NoteVector({
      for (final e in weights.entries) e.key: e.value / m,
    });
  }

  /// Cosine similarity in 0..1 (weights are non-negative, so it never goes
  /// below zero). Returns 0 when either side is empty rather than NaN — an
  /// empty collection must produce "no signal", not a crash.
  double cosine(NoteVector other) {
    if (isEmpty || other.isEmpty) return 0.0;
    final a = normalised();
    final b = other.normalised();
    // Iterate the smaller side: the intersection is what contributes.
    final (small, large) = a.weights.length <= b.weights.length
        ? (a.weights, b.weights)
        : (b.weights, a.weights);
    var dot = 0.0;
    for (final e in small.entries) {
      final o = large[e.key];
      if (o != null) dot += e.value * o;
    }
    return dot.clamp(0.0, 1.0);
  }

  /// The n heaviest notes, heaviest first. What an explanation is built from.
  List<MapEntry<String, double>> top(int n) {
    final entries = weights.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(n).toList();
  }
}

/// Catalog-wide statistics — the denominator every weight is judged against.
///
/// Built once from whatever slice of the catalog is loaded, and passed
/// explicitly rather than read from a global, so a test can hand it a five-item
/// catalog and know exactly what the IDF values are.
class CatalogStats {
  CatalogStats._(this.documentCount, this.noteDocumentFrequency, this.accordShare);

  /// How many fragrances the statistics were computed over.
  final int documentCount;

  /// note key → how many fragrances list it.
  final Map<String, int> noteDocumentFrequency;

  /// accord key → fraction of the catalog carrying it. The baseline the gap
  /// detector compares a collection against.
  final Map<String, double> accordShare;

  factory CatalogStats.from(Iterable<Fragrance> catalog) {
    final df = <String, int>{};
    final accordCounts = <String, int>{};
    var n = 0;

    for (final f in catalog) {
      n++;
      // A note listed in two tiers counts once toward document frequency —
      // otherwise a note in both heart and base looks twice as common as it is
      // and gets unfairly down-weighted everywhere.
      for (final key in f.notes.map((x) => x.key).toSet()) {
        df[key] = (df[key] ?? 0) + 1;
      }
      for (final key in f.accords.map((x) => x.key).toSet()) {
        accordCounts[key] = (accordCounts[key] ?? 0) + 1;
      }
    }

    final share = <String, double>{
      if (n > 0)
        for (final e in accordCounts.entries) e.key: e.value / n,
    };

    return CatalogStats._(n, df, share);
  }

  /// Smoothed inverse document frequency.
  ///
  ///   idf(note) = ln((1 + N) / (1 + df)) + 1
  ///
  /// The `+ 1` matters: with plain `ln(N/df)`, a note appearing in EVERY
  /// fragrance scores exactly zero and is erased from the vector entirely. That
  /// is wrong — bergamot being ubiquitous means it should count for little, not
  /// for nothing, and a collection of nothing but citrus openings still has a
  /// citrus opening in common. Smoothing floors it at 1 and lets a rare note
  /// (1 in 100) reach ~4.9, a spread of about five to one.
  ///
  /// An unseen note gets the maximum rather than a divide-by-zero: a note the
  /// catalog has never recorded is maximally distinctive, which is the correct
  /// reading.
  double idf(String noteKey) {
    final dfCount = noteDocumentFrequency[noteKey] ?? 0;
    return math.log((1 + documentCount) / (1 + dfCount)) + 1;
  }
}

/// The note vector for one fragrance: intrinsic tier/position weight × IDF.
NoteVector fragranceVector(Fragrance f, CatalogStats stats) {
  if (f.notes.isEmpty) return NoteVector.empty;
  final out = <String, double>{};
  for (final n in f.notes) {
    final w = n.intrinsicWeight * stats.idf(n.key);
    // A note in two tiers keeps the heavier reading rather than summing, so
    // "listed in heart AND base" does not outweigh a dedicated base note.
    final existing = out[n.key];
    out[n.key] = existing == null ? w : math.max(existing, w);
  }
  return NoteVector(out);
}

/// The centroid of everything owned, weighted by rating.
///
/// `want` items contribute nothing — see [CollectionItem.centroidWeight].
NoteVector collectionCentroid(
  Iterable<CollectionItem> items,
  CatalogStats stats,
) {
  final acc = <String, double>{};
  var totalWeight = 0.0;

  for (final item in items) {
    final w = item.centroidWeight;
    if (w == 0) continue;
    final v = fragranceVector(item.fragrance, stats).normalised();
    if (v.isEmpty) continue;
    totalWeight += w;
    for (final e in v.weights.entries) {
      acc[e.key] = (acc[e.key] ?? 0) + e.value * w;
    }
  }

  if (totalWeight == 0) return NoteVector.empty;
  return NoteVector({
    for (final e in acc.entries) e.key: e.value / totalWeight,
  });
}

// =============================================================================
// DETECTORS
// =============================================================================

/// Thresholds, named and in one place so they are tunable and testable.
///
/// Every one is a judgement call about when a tendency becomes a pattern worth
/// telling someone about. They are deliberately not buried in the functions
/// that use them.
abstract final class TasteThresholds {
  /// Above this share of clones, "buys clones" is the headline fact about a
  /// collection rather than a footnote.
  static const cloneShare = 0.5;

  /// A house is a loyalty when it is either this many bottles...
  static const loyalHouseCount = 3;

  /// ...or this share of the collection, whichever is reached first. Both,
  /// because 3 of 4 and 8 of 30 are each loyalty and neither rule catches both.
  static const loyalHouseShare = 0.30;

  /// A note appearing in at least this share of the collection is being chased
  /// deliberately, not landed on by accident.
  static const noteObsessionShare = 0.6;

  /// An accord is a gap when the collection carries it at less than this
  /// fraction of the catalog's own share of it.
  static const accordGapRatio = 0.25;

  /// Nothing below this many items produces a profile at all. Detectors on a
  /// two-bottle collection are noise dressed as insight — 3 of 3 is "you own
  /// three things", not a pattern.
  static const minimumCollectionForPatterns = 4;
}

/// What kind of pattern fired.
enum PatternKind {
  cloneBuyer,
  houseLoyalist,
  noteObsession,
  accordGap,
  tierConcentration,
  unverifiedData,
}

/// One detected pattern, with the numbers that produced it.
///
/// [evidence] carries the raw figures rather than a pre-formatted sentence, so
/// the UI decides the wording and a test can assert the arithmetic.
class TastePattern {
  const TastePattern({
    required this.kind,
    required this.headline,
    required this.detail,
    required this.evidence,
    this.subjectKey,
  });

  final PatternKind kind;

  /// Short, for a chip or a row title.
  final String headline;

  /// A sentence explaining what was counted. Never states a number the
  /// [evidence] does not contain.
  final String detail;

  final Map<String, num> evidence;

  /// The house key, note key or accord key this pattern is about, when it is
  /// about one. Lets a strategy act on the pattern without re-deriving it.
  final String? subjectKey;
}

/// Everything computed from a collection, in one value.
class TasteProfile {
  const TasteProfile({
    required this.itemCount,
    required this.centroid,
    required this.houseCounts,
    required this.tierCounts,
    required this.noteFrequency,
    required this.accordShare,
    required this.cloneCount,
    required this.patterns,
    required this.unverifiedCount,
  });

  final int itemCount;
  final NoteVector centroid;

  /// brand key → how many bottles.
  final Map<String, int> houseCounts;
  final Map<BrandTier, int> tierCounts;

  /// note key → share of the collection listing it, 0..1.
  final Map<String, double> noteFrequency;

  /// accord key → share of the collection carrying it, 0..1.
  final Map<String, double> accordShare;

  final int cloneCount;
  final List<TastePattern> patterns;

  /// How many owned fragrances still carry a model-proposed, unconfirmed
  /// pyramid. Surfaced because every number above is computed FROM those notes
  /// — a profile built on 80% unverified data deserves to say so.
  final int unverifiedCount;

  double get cloneShare => itemCount == 0 ? 0 : cloneCount / itemCount;

  bool get hasEnoughForPatterns =>
      itemCount >= TasteThresholds.minimumCollectionForPatterns;

  /// The house with the most bottles, or null on an empty collection.
  MapEntry<String, int>? get topHouse {
    if (houseCounts.isEmpty) return null;
    final sorted = houseCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first;
  }
}

/// Builds the profile. Pure: same collection and catalog in, same profile out.
TasteProfile buildTasteProfile({
  required List<CollectionItem> items,
  required CatalogStats stats,
}) {
  // `want` items are aspiration, not evidence — excluded from every statistic
  // for the same reason they are excluded from the centroid.
  final owned = items
      .where((i) => i.status != OwnershipStatus.want)
      .toList(growable: false);
  final n = owned.length;

  final houseCounts = <String, int>{};
  final tierCounts = <BrandTier, int>{};
  final noteCounts = <String, int>{};
  final accordCounts = <String, int>{};
  var cloneCount = 0;
  var unverifiedCount = 0;

  for (final item in owned) {
    final f = item.fragrance;
    houseCounts[f.brand.key] = (houseCounts[f.brand.key] ?? 0) + 1;
    tierCounts[f.brand.tier] = (tierCounts[f.brand.tier] ?? 0) + 1;
    if (f.isClone) cloneCount++;
    if (f.notesUnverified) unverifiedCount++;
    for (final key in f.notes.map((x) => x.key).toSet()) {
      noteCounts[key] = (noteCounts[key] ?? 0) + 1;
    }
    for (final key in f.accords.map((x) => x.key).toSet()) {
      accordCounts[key] = (accordCounts[key] ?? 0) + 1;
    }
  }

  final noteFrequency = <String, double>{
    if (n > 0)
      for (final e in noteCounts.entries) e.key: e.value / n,
  };
  final accordShare = <String, double>{
    if (n > 0)
      for (final e in accordCounts.entries) e.key: e.value / n,
  };

  final profile = TasteProfile(
    itemCount: n,
    centroid: collectionCentroid(owned, stats),
    houseCounts: houseCounts,
    tierCounts: tierCounts,
    noteFrequency: noteFrequency,
    accordShare: accordShare,
    cloneCount: cloneCount,
    patterns: const [],
    unverifiedCount: unverifiedCount,
  );

  return TasteProfile(
    itemCount: profile.itemCount,
    centroid: profile.centroid,
    houseCounts: profile.houseCounts,
    tierCounts: profile.tierCounts,
    noteFrequency: profile.noteFrequency,
    accordShare: profile.accordShare,
    cloneCount: profile.cloneCount,
    unverifiedCount: profile.unverifiedCount,
    patterns: detectPatterns(profile: profile, owned: owned, stats: stats),
  );
}

/// Runs every detector. Order of the returned list is significance order —
/// what the Taste screen shows first.
List<TastePattern> detectPatterns({
  required TasteProfile profile,
  required List<CollectionItem> owned,
  required CatalogStats stats,
}) {
  final out = <TastePattern>[];
  final n = profile.itemCount;

  // A collection too small to have a pattern says so, rather than reporting
  // "100% of your collection is designer" about two bottles.
  if (!profile.hasEnoughForPatterns) return out;

  // --- clone buyer ---------------------------------------------------------
  if (profile.cloneShare > TasteThresholds.cloneShare) {
    out.add(TastePattern(
      kind: PatternKind.cloneBuyer,
      headline: 'You buy clones',
      detail:
          '${profile.cloneCount} of your $n bottles are known dupes of another '
          'fragrance.',
      evidence: {'clones': profile.cloneCount, 'total': n},
    ));
  }

  // --- house loyalty -------------------------------------------------------
  final top = profile.topHouse;
  if (top != null &&
      (top.value >= TasteThresholds.loyalHouseCount ||
          top.value / n >= TasteThresholds.loyalHouseShare)) {
    // Only interesting when the house is not simply the whole collection of a
    // one-house shelf that has nothing to compare against.
    if (profile.houseCounts.length > 1) {
      final houseName = owned
          .firstWhere((i) => i.fragrance.brand.key == top.key)
          .fragrance
          .brand
          .displayName;
      out.add(TastePattern(
        kind: PatternKind.houseLoyalist,
        headline: 'Loyal to $houseName',
        detail: '${top.value} of your $n bottles are $houseName.',
        evidence: {'count': top.value, 'total': n},
        subjectKey: top.key,
      ));
    }
  }

  // --- note obsession ------------------------------------------------------
  final obsessions = profile.noteFrequency.entries
      .where((e) => e.value >= TasteThresholds.noteObsessionShare)
      .toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  for (final o in obsessions.take(3)) {
    final display = owned
        .expand((i) => i.fragrance.notes)
        .firstWhere(
          (nt) => nt.key == o.key,
          orElse: () => NoteRef(
            key: o.key,
            displayName: o.key,
            tier: NoteTier.heart,
          ),
        )
        .displayName;
    out.add(TastePattern(
      kind: PatternKind.noteObsession,
      headline: 'You chase $display',
      detail:
          '$display is in ${(o.value * 100).round()}% of what you own '
          '(${(o.value * n).round()} of $n).',
      evidence: {'share': o.value, 'total': n},
      subjectKey: o.key,
    ));
  }

  // --- accord gaps ---------------------------------------------------------
  // Compared against the CATALOG's own share, not against zero. "You own no
  // aquatics" is only interesting if aquatics are a meaningful part of what
  // exists — otherwise every obscure accord is a gap.
  final gaps = <MapEntry<String, double>>[];
  for (final e in stats.accordShare.entries) {
    if (e.value < 0.10) continue; // too rare in the catalog to call a gap
    final mine = profile.accordShare[e.key] ?? 0.0;
    if (mine < e.value * TasteThresholds.accordGapRatio) {
      gaps.add(MapEntry(e.key, e.value - mine));
    }
  }
  gaps.sort((a, b) => b.value.compareTo(a.value));
  for (final gap in gaps.take(2)) {
    out.add(TastePattern(
      kind: PatternKind.accordGap,
      headline: 'Nothing ${gap.key}',
      detail:
          'You own almost no ${gap.key} — it is in '
          '${((stats.accordShare[gap.key] ?? 0) * 100).round()}% of the catalog '
          'and ${((profile.accordShare[gap.key] ?? 0) * 100).round()}% of your '
          'shelf.',
      evidence: {
        'catalogShare': stats.accordShare[gap.key] ?? 0,
        'mine': profile.accordShare[gap.key] ?? 0,
      },
      subjectKey: gap.key,
    ));
  }

  // --- tier concentration --------------------------------------------------
  final dominantTier = profile.tierCounts.entries
      .where((e) => e.key != BrandTier.unknown)
      .fold<MapEntry<BrandTier, int>?>(
        null,
        (best, e) => best == null || e.value > best.value ? e : best,
      );
  if (dominantTier != null && dominantTier.value / n >= 0.75) {
    out.add(TastePattern(
      kind: PatternKind.tierConcentration,
      headline: 'Almost all ${dominantTier.key.label.toLowerCase()}',
      detail:
          '${dominantTier.value} of your $n bottles are '
          '${dominantTier.key.label.toLowerCase()}.',
      evidence: {'count': dominantTier.value, 'total': n},
    ));
  }

  // --- data honesty --------------------------------------------------------
  // Last, and always shown when it applies: every pattern above was computed
  // from note pyramids, and if most of those are unconfirmed the user should
  // know before acting on any of it.
  if (profile.unverifiedCount > 0 && profile.unverifiedCount / n >= 0.5) {
    out.add(TastePattern(
      kind: PatternKind.unverifiedData,
      headline: 'Mostly unverified notes',
      detail:
          '${profile.unverifiedCount} of $n pyramids are model-proposed and '
          'unconfirmed. Everything above is computed from them.',
      evidence: {'unverified': profile.unverifiedCount, 'total': n},
    ));
  }

  return out;
}
