/// Taste profile and recommender tests.
///
/// Every expected value here is either hand-computed from the formula in
/// `taste.dart` or a property that must hold for any input. Nothing asserts
/// golden output captured from a run — that would pin whatever the code happened
/// to do rather than what it is supposed to do.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sillage/core/identity.dart';
import 'package:sillage/core/models.dart';
import 'package:sillage/core/recommend.dart';
import 'package:sillage/core/taste.dart';

// =============================================================================
// FIXTURES
// =============================================================================

Brand _brand(String key, {BrandTier tier = BrandTier.designer}) =>
    Brand(key: key, displayName: key, tier: tier);

NoteRef _note(String key, NoteTier tier, {int position = 0, String? family}) =>
    NoteRef(key: key, displayName: key, tier: tier, position: position, family: family);

Fragrance _frag(
  String id, {
  String brand = 'house',
  BrandTier tier = BrandTier.designer,
  List<NoteRef> notes = const [],
  List<AccordRef> accords = const [],
  String? cloneOf,
  Provenance notesSource = Provenance.user,
}) => Fragrance(
  id: id,
  key: buildFragranceKey(rawBrand: brand, rawName: id),
  displayName: id,
  brand: _brand(brand, tier: tier),
  notes: notes,
  accords: accords,
  cloneOfId: cloneOf,
  notesSource: notesSource,
);

CollectionItem _item(Fragrance f, {double? rating, OwnershipStatus? status}) =>
    CollectionItem(
      id: 'item-${f.id}',
      fragrance: f,
      rating: rating,
      status: status ?? OwnershipStatus.have,
    );

void main() {
  // ===========================================================================
  group('note weighting', () {
    test('base outranks heart outranks top', () {
      expect(NoteTier.base.weight, greaterThan(NoteTier.heart.weight));
      expect(NoteTier.heart.weight, greaterThan(NoteTier.top.weight));
    });

    test('a late base note still outweighs a leading top note', () {
      // The ordering a nose would agree with, and the reason position decay is
      // gentle rather than steep.
      final lateBase = _note('a', NoteTier.base, position: 4).intrinsicWeight;
      final firstTop = _note('b', NoteTier.top, position: 0).intrinsicWeight;
      expect(lateBase, greaterThan(firstTop));
      // Hand-computed: 1.0 / (1 + 0.2*4) = 1/1.8 = 0.5555...
      expect(lateBase, closeTo(1 / 1.8, 1e-9));
      expect(firstTop, closeTo(0.4, 1e-9));
    });

    test('position decays within a tier', () {
      expect(
        _note('a', NoteTier.base, position: 0).intrinsicWeight,
        greaterThan(_note('a', NoteTier.base, position: 3).intrinsicWeight),
      );
    });
  });

  // ===========================================================================
  group('IDF', () {
    test('a note in every fragrance is down-weighted but NOT erased', () {
      // The whole reason for the +1 smoothing. Plain ln(N/df) gives exactly 0
      // here, which deletes the note from every vector.
      final catalog = [
        _frag('a', notes: [_note('bergamot', NoteTier.top)]),
        _frag('b', notes: [_note('bergamot', NoteTier.top)]),
        _frag('c', notes: [_note('bergamot', NoteTier.top)]),
      ];
      final stats = CatalogStats.from(catalog);
      // ln((1+3)/(1+3)) + 1 = ln(1) + 1 = 1
      expect(stats.idf('bergamot'), closeTo(1.0, 1e-9));
      expect(stats.idf('bergamot'), greaterThan(0));
    });

    test('a rare note scores far above a ubiquitous one', () {
      final catalog = [
        for (var i = 0; i < 99; i++)
          _frag('common$i', notes: [_note('bergamot', NoteTier.top)]),
        _frag('rare', notes: [
          _note('bergamot', NoteTier.top),
          _note('immortelle', NoteTier.base),
        ]),
      ];
      final stats = CatalogStats.from(catalog);
      // bergamot: df=100, N=100 -> ln(101/101)+1 = 1
      expect(stats.idf('bergamot'), closeTo(1.0, 1e-9));
      // immortelle: df=1, N=100 -> ln(101/2)+1
      expect(stats.idf('immortelle'), closeTo(math.log(101 / 2) + 1, 1e-9));
      expect(stats.idf('immortelle') / stats.idf('bergamot'), greaterThan(4));
    });

    test('a note the catalog has never seen is maximally distinctive', () {
      final stats = CatalogStats.from([_frag('a', notes: [_note('x', NoteTier.base)])]);
      // ln((1+1)/(1+0)) + 1 = ln(2)+1, above anything actually recorded.
      expect(stats.idf('never-seen'), closeTo(math.log(2) + 1, 1e-9));
      expect(stats.idf('never-seen'), greaterThan(stats.idf('x')));
    });

    test('a note listed in two tiers counts once toward document frequency', () {
      final stats = CatalogStats.from([
        _frag('a', notes: [
          _note('vanilla', NoteTier.heart),
          _note('vanilla', NoteTier.base),
        ]),
      ]);
      expect(stats.noteDocumentFrequency['vanilla'], 1);
    });
  });

  // ===========================================================================
  group('vectors', () {
    test('cosine of a vector with itself is 1', () {
      final f = _frag('a', notes: [
        _note('vanilla', NoteTier.base),
        _note('bergamot', NoteTier.top),
      ]);
      final stats = CatalogStats.from([f]);
      final v = fragranceVector(f, stats);
      expect(v.cosine(v), closeTo(1.0, 1e-9));
    });

    test('cosine of disjoint vectors is 0', () {
      final a = _frag('a', notes: [_note('vanilla', NoteTier.base)]);
      final b = _frag('b', notes: [_note('oud', NoteTier.base)]);
      final stats = CatalogStats.from([a, b]);
      expect(
        fragranceVector(a, stats).cosine(fragranceVector(b, stats)),
        closeTo(0.0, 1e-9),
      );
    });

    test('an empty vector yields 0, not NaN', () {
      final stats = CatalogStats.from(const <Fragrance>[]);
      final empty = fragranceVector(_frag('a'), stats);
      expect(empty.isEmpty, isTrue);
      expect(empty.cosine(empty), 0.0);
      expect(empty.cosine(empty).isNaN, isFalse);
    });

    test('a long ingredient list does not beat a better match', () {
      // The reason vectors are normalised before comparison.
      final target = _frag('target', notes: [_note('vanilla', NoteTier.base)]);
      final exact = _frag('exact', notes: [_note('vanilla', NoteTier.base)]);
      final padded = _frag('padded', notes: [
        _note('vanilla', NoteTier.base),
        for (var i = 0; i < 15; i++) _note('filler$i', NoteTier.base),
      ]);
      final stats = CatalogStats.from([target, exact, padded]);
      final t = fragranceVector(target, stats);
      expect(
        t.cosine(fragranceVector(exact, stats)),
        greaterThan(t.cosine(fragranceVector(padded, stats))),
      );
    });

    test('a note in two tiers keeps the heavier reading, not the sum', () {
      final f = _frag('a', notes: [
        _note('vanilla', NoteTier.heart),
        _note('vanilla', NoteTier.base),
      ]);
      final stats = CatalogStats.from([f]);
      final v = fragranceVector(f, stats);
      // base (1.0) rather than base + heart (1.7), times idf.
      expect(v.weights['vanilla'], closeTo(1.0 * stats.idf('vanilla'), 1e-9));
    });
  });

  // ===========================================================================
  group('the centroid', () {
    test('a rated bottle pulls harder than an unrated one', () {
      expect(_item(_frag('a'), rating: 10).centroidWeight, closeTo(1.5, 1e-9));
      expect(_item(_frag('a')).centroidWeight, closeTo(1.0, 1e-9));
      expect(_item(_frag('a'), rating: 0).centroidWeight, closeTo(0.5, 1e-9));
    });

    test('a want contributes nothing to the centroid', () {
      final wanted = _item(_frag('a'), status: OwnershipStatus.want);
      expect(wanted.centroidWeight, 0.0);
    });

    test('wants are excluded from the profile entirely', () {
      final owned = _frag('owned', notes: [_note('vanilla', NoteTier.base)]);
      final wanted = _frag('wanted', notes: [_note('oud', NoteTier.base)]);
      final stats = CatalogStats.from([owned, wanted]);
      final profile = buildTasteProfile(
        items: [
          _item(owned),
          _item(wanted, status: OwnershipStatus.want),
        ],
        stats: stats,
      );
      expect(profile.itemCount, 1);
      expect(profile.noteFrequency.containsKey('oud'), isFalse);
    });

    test('an empty collection yields an empty centroid, not a crash', () {
      final profile = buildTasteProfile(
        items: const [],
        stats: CatalogStats.from(const <Fragrance>[]),
      );
      expect(profile.itemCount, 0);
      expect(profile.centroid.isEmpty, isTrue);
      expect(profile.cloneShare, 0.0);
      expect(profile.patterns, isEmpty);
    });
  });

  // ===========================================================================
  group('detectors do not fire on a collection too small to have a pattern', () {
    test('three bottles from one house produce nothing', () {
      // 3 of 3 is "you own three things", not loyalty.
      final frags = [
        for (var i = 0; i < 3; i++)
          _frag('f$i', brand: 'dior', notes: [_note('vanilla', NoteTier.base)]),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      expect(profile.hasEnoughForPatterns, isFalse);
      expect(profile.patterns, isEmpty);
    });

    test('the fourth bottle is where patterns begin', () {
      final frags = [
        for (var i = 0; i < 4; i++)
          _frag('f$i', brand: 'dior', notes: [_note('vanilla', NoteTier.base)]),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      expect(profile.hasEnoughForPatterns, isTrue);
    });
  });

  // ===========================================================================
  group('clone detector', () {
    test('fires on a majority-clone shelf', () {
      final original = _frag('aventus', brand: 'creed', tier: BrandTier.niche);
      final frags = [
        _frag('cdni', brand: 'armaf', cloneOf: original.id),
        _frag('dupe2', brand: 'lattafa', cloneOf: original.id),
        _frag('dupe3', brand: 'alexandria', cloneOf: original.id),
        _frag('real1', brand: 'dior'),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from([...frags, original]),
      );
      expect(profile.cloneCount, 3);
      expect(profile.cloneShare, closeTo(0.75, 1e-9));
      expect(
        profile.patterns.any((p) => p.kind == PatternKind.cloneBuyer),
        isTrue,
      );
    });

    test('does not fire at exactly the threshold — it is a strict majority', () {
      final original = _frag('aventus', brand: 'creed');
      final frags = [
        _frag('d1', brand: 'armaf', cloneOf: original.id),
        _frag('d2', brand: 'armaf', cloneOf: original.id),
        _frag('r1', brand: 'dior'),
        _frag('r2', brand: 'chanel'),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      expect(profile.cloneShare, closeTo(0.5, 1e-9));
      expect(
        profile.patterns.any((p) => p.kind == PatternKind.cloneBuyer),
        isFalse,
      );
    });

    test('keys off the clone edge, never off the house being an Arabian one', () {
      // Lattafa releases originals too. A collection of four Lattafas with no
      // clone edges is not a clone collection.
      final frags = [
        for (var i = 0; i < 4; i++) _frag('l$i', brand: 'lattafa', tier: BrandTier.arabian),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      expect(profile.cloneCount, 0);
      expect(
        profile.patterns.any((p) => p.kind == PatternKind.cloneBuyer),
        isFalse,
      );
    });
  });

  // ===========================================================================
  group('house loyalty detector', () {
    test('fires on three of five from one house', () {
      final frags = [
        _frag('a', brand: 'parfumsdemarly'),
        _frag('b', brand: 'parfumsdemarly'),
        _frag('c', brand: 'parfumsdemarly'),
        _frag('d', brand: 'dior'),
        _frag('e', brand: 'chanel'),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      final pattern = profile.patterns
          .where((p) => p.kind == PatternKind.houseLoyalist)
          .firstOrNull;
      expect(pattern, isNotNull);
      expect(pattern!.subjectKey, 'parfumsdemarly');
      expect(pattern.evidence['count'], 3);
      expect(pattern.evidence['total'], 5);
    });

    test('does not fire when the shelf is a single house with no contrast', () {
      // "100% one house" on a one-house shelf is a description, not a pattern.
      final frags = [
        for (var i = 0; i < 5; i++) _frag('f$i', brand: 'dior'),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      expect(
        profile.patterns.any((p) => p.kind == PatternKind.houseLoyalist),
        isFalse,
      );
    });

    test('the share rule catches loyalty the count rule would miss', () {
      // 8 of 25 is 32% — over the share threshold, and well over the count one.
      final frags = [
        for (var i = 0; i < 8; i++) _frag('m$i', brand: 'parfumsdemarly'),
        for (var i = 0; i < 17; i++) _frag('o$i', brand: 'house$i'),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      final pattern = profile.patterns
          .where((p) => p.kind == PatternKind.houseLoyalist)
          .firstOrNull;
      expect(pattern?.subjectKey, 'parfumsdemarly');
    });
  });

  // ===========================================================================
  group('note obsession detector', () {
    test('fires on a note in most of the collection', () {
      final frags = [
        for (var i = 0; i < 4; i++)
          _frag('f$i', brand: 'h$i', notes: [_note('vanilla', NoteTier.base)]),
        _frag('other', brand: 'x', notes: [_note('oud', NoteTier.base)]),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      final pattern = profile.patterns
          .where((p) => p.kind == PatternKind.noteObsession)
          .firstOrNull;
      expect(pattern, isNotNull);
      expect(pattern!.subjectKey, 'vanilla');
      // 4 of 5 = 0.8
      expect(pattern.evidence['share'], closeTo(0.8, 1e-9));
    });

    test('does not fire below the threshold', () {
      final frags = [
        _frag('a', brand: 'h1', notes: [_note('vanilla', NoteTier.base)]),
        _frag('b', brand: 'h2', notes: [_note('vanilla', NoteTier.base)]),
        _frag('c', brand: 'h3', notes: [_note('oud', NoteTier.base)]),
        _frag('d', brand: 'h4', notes: [_note('rose', NoteTier.base)]),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      // vanilla is 2 of 4 = 0.5, below 0.6
      expect(
        profile.patterns.any((p) => p.kind == PatternKind.noteObsession),
        isFalse,
      );
    });
  });

  // ===========================================================================
  group('data honesty', () {
    test('a mostly-unverified shelf says so', () {
      final frags = [
        for (var i = 0; i < 4; i++)
          _frag('f$i', brand: 'h$i', notesSource: Provenance.model),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      expect(profile.unverifiedCount, 4);
      final pattern = profile.patterns
          .where((p) => p.kind == PatternKind.unverifiedData)
          .firstOrNull;
      expect(pattern, isNotNull);
      expect(pattern!.evidence['unverified'], 4);
    });

    test('a verified shelf does not', () {
      final frags = [
        for (var i = 0; i < 4; i++)
          _frag('f$i', brand: 'h$i', notesSource: Provenance.user),
      ];
      final profile = buildTasteProfile(
        items: frags.map(_item).toList(),
        stats: CatalogStats.from(frags),
      );
      expect(profile.unverifiedCount, 0);
      expect(
        profile.patterns.any((p) => p.kind == PatternKind.unverifiedData),
        isFalse,
      );
    });
  });

  // ===========================================================================
  group('recommender', () {
    test('never recommends something already owned', () {
      final owned = _frag('owned', notes: [_note('vanilla', NoteTier.base)]);
      final candidate = _frag('new', notes: [_note('vanilla', NoteTier.base)]);
      final stats = CatalogStats.from([owned, candidate]);
      final items = [_item(owned)];
      final result = recommend(RecommendationInput(
        profile: buildTasteProfile(items: items, stats: stats),
        owned: items,
        candidates: [owned, candidate],
        stats: stats,
      ));
      final all = result.values.expand((x) => x).toList();
      expect(all.map((r) => r.fragrance.id), isNot(contains('owned')));
    });

    test('never recommends something on the want list either', () {
      final owned = _frag('owned', notes: [_note('vanilla', NoteTier.base)]);
      final wanted = _frag('wanted', notes: [_note('vanilla', NoteTier.base)]);
      final stats = CatalogStats.from([owned, wanted]);
      final items = [_item(owned), _item(wanted, status: OwnershipStatus.want)];
      final result = recommend(RecommendationInput(
        profile: buildTasteProfile(items: items, stats: stats),
        owned: items,
        candidates: [wanted],
        stats: stats,
      ));
      expect(result.values.expand((x) => x), isEmpty);
    });

    test('every recommendation carries a non-empty explanation', () {
      final owned = [
        for (var i = 0; i < 4; i++)
          _frag('o$i', brand: 'dior', notes: [
            _note('vanilla', NoteTier.base),
            _note('bergamot', NoteTier.top),
          ]),
      ];
      final candidates = [
        _frag('c1', brand: 'dior', notes: [_note('vanilla', NoteTier.base)]),
        _frag('c2', brand: 'chanel', notes: [_note('vanilla', NoteTier.heart)]),
      ];
      final stats = CatalogStats.from([...owned, ...candidates]);
      final items = owned.map(_item).toList();
      final result = recommend(RecommendationInput(
        profile: buildTasteProfile(items: items, stats: stats),
        owned: items,
        candidates: candidates,
        stats: stats,
      ));
      final all = result.values.expand((x) => x).toList();
      expect(all, isNotEmpty);
      for (final r in all) {
        expect(r.explanation.trim(), isNotEmpty, reason: r.fragrance.id);
        expect(r.score, inInclusiveRange(0.0, 1.0));
      }
    });

    test('neighbour ranks the closer fragrance first', () {
      final owned = _frag('owned', notes: [
        _note('vanilla', NoteTier.base),
        _note('tonka', NoteTier.base),
      ]);
      final close = _frag('close', notes: [
        _note('vanilla', NoteTier.base),
        _note('tonka', NoteTier.base),
      ]);
      final far = _frag('far', notes: [
        _note('vanilla', NoteTier.top, position: 4),
        _note('aquatic', NoteTier.base),
      ]);
      final stats = CatalogStats.from([owned, close, far]);
      final items = [_item(owned)];
      final result = recommend(RecommendationInput(
        profile: buildTasteProfile(items: items, stats: stats),
        owned: items,
        candidates: [far, close],
        stats: stats,
      ));
      final neighbours = result[RecStrategy.neighbour]!;
      expect(neighbours.first.fragrance.id, 'close');
      expect(neighbours.first.drivingNotes, isNotEmpty);
    });

    test('the clone pattern points at the original and says which dupe', () {
      final original = _frag('aventus', brand: 'creed', tier: BrandTier.niche);
      final owned = [
        _frag('cdni', brand: 'armaf', cloneOf: original.id),
        _frag('d2', brand: 'lattafa', cloneOf: original.id),
        _frag('d3', brand: 'alexandria', cloneOf: original.id),
        _frag('r1', brand: 'dior'),
      ];
      final stats = CatalogStats.from([...owned, original]);
      final items = owned.map(_item).toList();
      final result = recommend(RecommendationInput(
        profile: buildTasteProfile(items: items, stats: stats),
        owned: items,
        candidates: [original],
        stats: stats,
      ));
      final patterns = result[RecStrategy.pattern]!;
      expect(patterns, isNotEmpty);
      expect(patterns.first.fragrance.id, 'aventus');
      expect(patterns.first.explanation, contains('dupe'));
      expect(patterns.first.relatedFragranceId, isNotNull);
    });

    test('a single owned clone surfaces its original, without a clone majority',
        () {
      // The regression this pins: the clone -> original suggestion used to be
      // gated on the clone-BUYER detector, which needs a strict majority. A
      // shelf of one dupe in five therefore produced no suggestion at all —
      // hiding the app's most distinctive recommendation from most real
      // collections. The edge is the evidence; the detector is only commentary.
      final original = _frag('aventus', brand: 'creed', tier: BrandTier.niche);
      final owned = [
        _frag('cdni', brand: 'armaf', cloneOf: original.id),
        _frag('r1', brand: 'dior'),
        _frag('r2', brand: 'chanel'),
        _frag('r3', brand: 'ysl'),
        _frag('r4', brand: 'prada'),
      ];
      final stats = CatalogStats.from([...owned, original]);
      final items = owned.map(_item).toList();
      final profile = buildTasteProfile(items: items, stats: stats);

      // 1 of 5 is well under the threshold — the detector must NOT fire...
      expect(profile.patterns.any((p) => p.kind == PatternKind.cloneBuyer),
          isFalse);

      // ...and the recommendation must appear anyway.
      final result = recommend(RecommendationInput(
        profile: profile,
        owned: items,
        candidates: [original],
        stats: stats,
      ));
      final patterns = result[RecStrategy.pattern]!;
      expect(patterns.map((r) => r.fragrance.id), contains('aventus'));
      final rec = patterns.firstWhere((r) => r.fragrance.id == 'aventus');
      expect(rec.explanation, contains('dupe'));
      expect(rec.relatedFragranceId, isNotNull);
      // No majority, so no "N of your M" tail claiming one.
      expect(rec.explanation, isNot(contains('of your')));
    });

    test('with a clone majority the explanation gains the count', () {
      final original = _frag('aventus', brand: 'creed');
      final owned = [
        _frag('c1', brand: 'armaf', cloneOf: original.id),
        _frag('c2', brand: 'lattafa', cloneOf: original.id),
        _frag('c3', brand: 'alexandria', cloneOf: original.id),
        _frag('r1', brand: 'dior'),
      ];
      final stats = CatalogStats.from([...owned, original]);
      final items = owned.map(_item).toList();
      final result = recommend(RecommendationInput(
        profile: buildTasteProfile(items: items, stats: stats),
        owned: items,
        candidates: [original],
        stats: stats,
      ));
      final rec = result[RecStrategy.pattern]!
          .firstWhere((r) => r.fragrance.id == 'aventus');
      expect(rec.explanation, contains('3 of your 4'));
    });

    test('a fragrance qualifying twice appears once', () {
      // The house you are loyal to also makes the note you chase.
      final owned = [
        for (var i = 0; i < 4; i++)
          _frag('o$i', brand: 'dior', notes: [_note('vanilla', NoteTier.base)]),
        _frag('other', brand: 'chanel', notes: [_note('vanilla', NoteTier.base)]),
      ];
      final candidate = _frag('both', brand: 'dior', notes: [
        _note('vanilla', NoteTier.base),
      ]);
      final stats = CatalogStats.from([...owned, candidate]);
      final items = owned.map(_item).toList();
      final result = recommend(RecommendationInput(
        profile: buildTasteProfile(items: items, stats: stats),
        owned: items,
        candidates: [candidate],
        stats: stats,
      ));
      final patterns = result[RecStrategy.pattern]!;
      expect(patterns.where((r) => r.fragrance.id == 'both').length, 1);
    });

    test('an empty candidate pool yields empty groups, not a crash', () {
      final owned = [
        for (var i = 0; i < 4; i++) _frag('o$i', brand: 'h$i'),
      ];
      final stats = CatalogStats.from(owned);
      final items = owned.map(_item).toList();
      final result = recommend(RecommendationInput(
        profile: buildTasteProfile(items: items, stats: stats),
        owned: items,
        candidates: const [],
        stats: stats,
      ));
      expect(result[RecStrategy.neighbour], isEmpty);
      expect(result[RecStrategy.gap], isEmpty);
      expect(result[RecStrategy.pattern], isEmpty);
    });

    test('perStrategy caps each group independently', () {
      final owned = [
        for (var i = 0; i < 4; i++)
          _frag('o$i', brand: 'dior', notes: [_note('vanilla', NoteTier.base)]),
        _frag('x', brand: 'chanel', notes: [_note('vanilla', NoteTier.base)]),
      ];
      final candidates = [
        for (var i = 0; i < 20; i++)
          _frag('c$i', brand: 'dior', notes: [_note('vanilla', NoteTier.base)]),
      ];
      final stats = CatalogStats.from([...owned, ...candidates]);
      final items = owned.map(_item).toList();
      final result = recommend(
        RecommendationInput(
          profile: buildTasteProfile(items: items, stats: stats),
          owned: items,
          candidates: candidates,
          stats: stats,
        ),
        perStrategy: 3,
      );
      for (final group in result.values) {
        expect(group.length, lessThanOrEqualTo(3));
      }
    });
  });
}
