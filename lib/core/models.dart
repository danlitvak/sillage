/// Domain models.
///
/// Pure Dart with no Flutter and no Supabase import, so the whole taste and
/// recommendation layer is exercisable in a unit test with no device, no
/// network and no database. Everything that talks to Postgres converts at the
/// edge — see `lib/data/`.
library;

import 'identity.dart';

/// Where a note sits in the pyramid.
enum NoteTier {
  top('top'),
  heart('heart'),
  base('base');

  const NoteTier(this.wire);
  final String wire;

  static NoteTier fromWire(String? v) => switch (v) {
    'top' => NoteTier.top,
    'base' => NoteTier.base,
    _ => NoteTier.heart,
  };

  /// How much this tier counts toward what a fragrance smells LIKE.
  ///
  /// Not equal, and the inequality is the point. Top notes evaporate in about
  /// fifteen minutes; base notes are what is still on skin six hours later and
  /// what people mean when they say a fragrance is "a vanilla" or "a woody".
  /// Weighting all three tiers equally makes every citrus-opening fragrance
  /// look alike, which is most of them.
  double get weight => switch (this) {
    NoteTier.base => 1.0,
    NoteTier.heart => 0.7,
    NoteTier.top => 0.4,
  };
}

/// What kind of house this is.
///
/// A display and secondary-signal hint only. The clone detector keys off an
/// actual [Fragrance.cloneOfId] edge, never off this — the Arabian houses
/// release plenty of originals alongside their dupes, and judging a collection
/// by the house's reputation misreads it.
enum BrandTier {
  designer('designer'),
  niche('niche'),
  cloneHouse('clone_house'),
  arabian('arabian'),
  indie('indie'),
  celebrity('celebrity'),
  unknown('unknown');

  const BrandTier(this.wire);
  final String wire;

  static BrandTier fromWire(String? v) {
    for (final t in BrandTier.values) {
      if (t.wire == v) return t;
    }
    return BrandTier.unknown;
  }

  String get label => switch (this) {
    BrandTier.designer => 'Designer',
    BrandTier.niche => 'Niche',
    BrandTier.cloneHouse => 'Clone house',
    BrandTier.arabian => 'Arabian',
    BrandTier.indie => 'Indie',
    BrandTier.celebrity => 'Celebrity',
    BrandTier.unknown => 'Unclassified',
  };
}

enum OwnershipStatus {
  have('have'),
  had('had'),
  want('want');

  const OwnershipStatus(this.wire);
  final String wire;

  static OwnershipStatus fromWire(String? v) => switch (v) {
    'had' => OwnershipStatus.had,
    'want' => OwnershipStatus.want,
    _ => OwnershipStatus.have,
  };
}

/// Where a fact came from. Precedence: [user] > [brand] > [model].
enum Provenance {
  model('model', 1),
  brand('brand', 2),
  user('user', 3);

  const Provenance(this.wire, this.rank);
  final String wire;
  final int rank;

  static Provenance fromWire(String? v) => switch (v) {
    'user' => Provenance.user,
    'brand' => Provenance.brand,
    _ => Provenance.model,
  };

  /// Whether the UI should mark this as unverified.
  bool get isUnverified => this == Provenance.model;
}

class Brand {
  const Brand({
    required this.key,
    required this.displayName,
    this.tier = BrandTier.unknown,
  });

  final String key;
  final String displayName;
  final BrandTier tier;
}

/// One note as it appears on one fragrance.
class NoteRef {
  const NoteRef({
    required this.key,
    required this.displayName,
    required this.tier,
    this.position = 0,
    this.family,
  });

  final String key;
  final String displayName;
  final NoteTier tier;

  /// Where the house listed it within its tier. Houses put the most prominent
  /// first, so this is signal rather than presentation order.
  final int position;

  final String? family;

  /// Tier weight, decayed by how far down its tier the note was listed.
  ///
  /// Gentle on purpose: a fifth-listed base note still matters more than a
  /// first-listed top note (1.0/1.8 = 0.56 against 0.4), which is the ordering
  /// a nose would agree with.
  double get intrinsicWeight => tier.weight / (1.0 + 0.2 * position);
}

class AccordRef {
  const AccordRef({
    required this.key,
    required this.displayName,
    this.weight = 1.0,
  });

  final String key;
  final String displayName;
  final double weight;
}

class Fragrance {
  const Fragrance({
    required this.id,
    required this.key,
    required this.displayName,
    required this.brand,
    this.notes = const [],
    this.accords = const [],
    this.releaseYear,
    this.perfumer,
    this.cloneOfId,
    this.notesSource = Provenance.model,
  });

  final String id;
  final FragranceKey key;

  /// Verbatim as the house writes it — diacritics and capitals intact. Never
  /// derived from the key at display time.
  final String displayName;

  final Brand brand;
  final List<NoteRef> notes;
  final List<AccordRef> accords;
  final int? releaseYear;
  final String? perfumer;

  /// Set when this fragrance is a known dupe of another. The clone detector's
  /// only input — see the comment on [BrandTier].
  final String? cloneOfId;

  final Provenance notesSource;

  bool get isClone => cloneOfId != null;

  /// True when the pyramid is model-proposed and nobody has confirmed it. The
  /// UI marks these; it is not decoration.
  bool get notesUnverified => notesSource.isUnverified;

  Concentration get concentration => key.concentration;

  /// How it reads in a list: "Sauvage · EDP".
  String get subtitle => key.concentration == Concentration.unknown
      ? brand.displayName
      : '${brand.displayName} · ${key.concentration.short}';
}

class CollectionItem {
  const CollectionItem({
    required this.id,
    required this.fragrance,
    this.status = OwnershipStatus.have,
    this.rating,
    this.photoPath,
    this.bottleMl,
    this.acquiredOn,
    this.note,
  });

  final String id;
  final Fragrance fragrance;
  final OwnershipStatus status;

  /// 0..10.
  final double? rating;

  final String? photoPath;
  final int? bottleMl;
  final DateTime? acquiredOn;
  final String? note;

  /// How hard this bottle pulls the taste centroid.
  ///
  /// An unrated bottle counts as exactly one. A rated one ranges 0.5 to 1.5, so
  /// a bottle you love pulls roughly three times as hard as one you tolerate —
  /// enough to matter, not enough for a single 10 to drown out the rest of a
  /// collection.
  ///
  /// A `want` is aspiration rather than evidence of taste, and is excluded from
  /// the profile entirely rather than down-weighted: including wants would make
  /// the recommender recommend things adjacent to what you already decided to
  /// buy, which is the one thing it does not need to help with.
  double get centroidWeight {
    if (status == OwnershipStatus.want) return 0.0;
    final r = rating;
    if (r == null) return 1.0;
    return 0.5 + (r / 10.0);
  }
}
