/// Catalog identity: turning what a model read off a label into ONE stable key.
///
/// ---------------------------------------------------------------------------
/// WHY THIS FILE EXISTS AND WHY IT IS THE FIRST THING BUILT
/// ---------------------------------------------------------------------------
/// The catalog is keyed on `(brand, name, concentration)`. Get that key wrong in
/// either direction and the failure is SILENT:
///
///   TOO LOOSE  — two different fragrances collapse into one row, so a note
///                pyramid from one bottle is shown for another. Nothing errors.
///   TOO TIGHT  — one fragrance forks into several rows, so your collection
///                shows three Sauvages, the IDF weights in the recommender are
///                computed against a catalog that double-counts, and the
///                house-loyalty detector reads a split house as two houses.
///
/// Neither shows up as an exception, a failed request, or a red screen. They
/// show up as an app that is quietly wrong, which is why this is written and
/// tested before anything is allowed to write to the catalog. It is the same
/// class of problem as `knockabase`'s door identity (migration 0022, where a
/// CSV dedupe key got promoted by accident into "is this the same door" and
/// merged neighbours 40m apart).
///
/// ---------------------------------------------------------------------------
/// THE THREE JUDGEMENT CALLS, STATED OUT LOUD
/// ---------------------------------------------------------------------------
/// 1. THE KEY IS SPACE-FREE. `L'Homme`, `L Homme` and `LHomme` all have to land
///    on one row, and no amount of apostrophe handling gets there while spaces
///    still count — stripping the apostrophe turns the first into `lhomme` and
///    leaves the second as `l homme`. So separators are removed entirely rather
///    than normalised. This trades a small risk of false merge (two real
///    fragrances differing ONLY by where a space falls) against a large and
///    routine risk of false split, and the split is the worse failure: it is
///    invisible in the UI and it corrupts the recommender's arithmetic.
///
/// 2. `&` AND THE WORD `and` ARE DROPPED, not mapped to each other. `Dolce &
///    Gabbana`, `Dolce and Gabbana` and `Dolce Gabbana` are all written on real
///    packaging and in real model output. Mapping `&`→`and` reconciles the
///    first two and strands the third; dropping both reconciles all three.
///
/// 3. `Elixir`, `Intense`, `Absolu`, `Extreme` and `Le Parfum` STAY IN THE NAME
///    and are not treated as concentrations. They read like strengths but they
///    are product names: Sauvage Elixir is a different fragrance from Sauvage
///    EDP, not the same juice at a different concentration, and Dior Homme
///    Intense has a different note pyramid from Dior Homme. Only the six
///    genuine concentrations below are lifted out of the name. Getting this
///    backwards would merge fragrances that smell nothing alike.
///
/// Pure Dart, no Flutter import — so the test suite runs in milliseconds and the
/// whole file is exercisable without a device.
library;

/// How strong the juice is.
///
/// Deliberately SMALL. Every value here is a genuine concentration that a house
/// uses to sell the same composition at a different strength. Marketing words
/// that merely sound like strengths stay in the name — see judgement call 3.
enum Concentration {
  /// Extrait de Parfum, Pure Parfum, or a bare "Parfum" on the label.
  extrait('extrait'),

  /// Eau de Parfum.
  edp('edp'),

  /// Eau de Toilette.
  edt('edt'),

  /// Eau de Cologne, or a bare "Cologne".
  edc('edc'),

  /// Eau Fraiche — the weakest of the sprayed concentrations.
  eauFraiche('eau_fraiche'),

  /// Perfume oil / attar. Common in the Arabian houses.
  oil('oil'),

  /// Not stated on the label, or not legible in the photo.
  ///
  /// A real and expected outcome, NOT an error: plenty of bottles do not print
  /// it, and a photo taken at an angle often cannot resolve the small type. The
  /// confirm sheet asks rather than the model guessing.
  unknown('unknown');

  const Concentration(this.wire);

  /// Stable string used in the database and on the wire. Never the enum's Dart
  /// name — renaming a Dart identifier must not silently re-key the catalog.
  final String wire;

  static Concentration fromWire(String? value) {
    if (value == null) return Concentration.unknown;
    for (final c in Concentration.values) {
      if (c.wire == value) return c;
    }
    return Concentration.unknown;
  }

  /// How it is written on a bottle.
  String get label => switch (this) {
    Concentration.extrait => 'Extrait de Parfum',
    Concentration.edp => 'Eau de Parfum',
    Concentration.edt => 'Eau de Toilette',
    Concentration.edc => 'Eau de Cologne',
    Concentration.eauFraiche => 'Eau Fraiche',
    Concentration.oil => 'Perfume Oil',
    Concentration.unknown => 'Unspecified',
  };

  /// The short form people actually say.
  String get short => switch (this) {
    Concentration.extrait => 'Extrait',
    Concentration.edp => 'EDP',
    Concentration.edt => 'EDT',
    Concentration.edc => 'EDC',
    Concentration.eauFraiche => 'Fraiche',
    Concentration.oil => 'Oil',
    Concentration.unknown => '—',
  };
}

/// Concentration spellings, in **containment order**.
///
/// The ordering is load-bearing, not cosmetic. `eau de parfum` CONTAINS
/// `parfum`, and `eau de cologne` contains `cologne`. Match in the wrong order
/// and every EDP in the catalog is filed as an extrait — a bug that yields a
/// perfectly plausible-looking app in which half the collection carries the
/// wrong strength against the right name, and nothing anywhere throws.
///
/// The invariant is NOT "longest first" — `eau de toilette` (15) legitimately
/// follows `eau de parfum` (13). It is: **if one pattern is a substring of
/// another, the longer one must come first.** That is what a test asserts, so
/// an appended entry cannot quietly reorder the list into a wrong answer.
const List<(String, Concentration)> concentrationPatterns = [
  ('eau de parfum', Concentration.edp),
  ('eau de toilette', Concentration.edt),
  ('eau de cologne', Concentration.edc),
  ('extrait de parfum', Concentration.extrait),
  ('parfum de toilette', Concentration.edt),
  ('eau de perfume', Concentration.edp), // common misspelling in the wild
  ('perfume extract', Concentration.extrait),
  ('pure perfume', Concentration.extrait),
  ('eau fraiche', Concentration.eauFraiche),
  ('perfume oil', Concentration.oil),
  ('parfum oil', Concentration.oil),
  ('pure parfum', Concentration.extrait),
  ('extrait', Concentration.extrait),
  ('cologne', Concentration.edc),
  ('parfum', Concentration.extrait),
  ('attar', Concentration.oil),
  ('edp', Concentration.edp),
  ('edt', Concentration.edt),
  ('edc', Concentration.edc),
];

/// Latin letters that carry diacritics in real fragrance names.
///
/// Hermès, Frédéric Malle, Acqua di Parmà, L'Heure Bleue, Køln. Dart has no
/// Unicode normalisation in the core library, so this is explicit rather than
/// derived — which is fine, because the domain is Latin-script brand names and
/// the set is closed and short.
const Map<String, String> _diacritics = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
  'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y', 'š': 's', 'ž': 'z',
  'æ': 'ae', 'œ': 'oe', 'ß': 'ss',
  // Not a diacritic, but it appears on Chanel packaging and nowhere else, and
  // it has to agree with the `No 5` and `Number 5` spellings.
  '°': 'o',
};

/// Words dropped wholesale from keys.
///
/// `and` / `&` for the reason in judgement call 2. The rest are packaging noise
/// that appears on some photos of a bottle and not others — a model reading a
/// box will pick up "spray" and "for men", and a model reading the bottle will
/// not, and those two photos must not produce two catalog rows.
const Set<String> _noiseWords = {
  'and',
  'spray',
  'vaporisateur',
  'natural',
  'ml',
  'oz',
  'fl',
};

/// Gender markers. **Deliberately NOT stripped from keys.**
///
/// ---------------------------------------------------------------------------
/// THIS LIST EXISTS TO SUGGEST A MERGE, NEVER TO PERFORM ONE
/// ---------------------------------------------------------------------------
/// The first version of this file dropped these from the key, reasoning that
/// `Versace Eros Pour Homme EDT` and `Versace Eros EDT` are one bottle written
/// two ways — which they are. But run the same rule across the catalog and it
/// also merges:
///
///   Creed Aventus            with  Creed Aventus **for Her**
///   Versace Eros             with  Versace Eros **Pour Femme**
///   Armani Code Pour Homme   with  Armani Code Pour Femme
///
/// Those are genuinely different fragrances with different pyramids, and
/// merging them is the exact failure this file exists to prevent: the app would
/// show one bottle's notes under another bottle's name, silently.
///
/// A false SPLIT (`Eros` and `Eros Pour Homme` as two rows) is the lesser
/// failure and, unlike a false merge, it is recoverable — so gendering stays in
/// the key, and [genderVariantOf] is offered to the confirm sheet instead, where
/// a human decides. Suggest, don't merge.
const Set<String> genderPhrases = {
  'pour homme',
  'pour femme',
  'for men',
  'for women',
  'for him',
  'for her',
  'homme',
  'femme',
  'men',
  'women',
  'man',
  'woman',
  'uomo',
  'donna',
};

/// Brand aliases → canonical brand key.
///
/// Houses rename (Paco Rabanne became Rabanne in 2023, Thierry Mugler became
/// Mugler), abbreviate (YSL, MFK, PdM, JPG), and get written with or without a
/// founder's first name (Christian Dior / Dior, Frédéric Malle / Editions de
/// Parfums). All of those reach this code as different strings for one house.
///
/// The house is also what the loyalty detector counts, so a split house does
/// not merely look untidy — it hides the exact pattern the app exists to spot.
/// Sub-lines are folded into their parent house on purpose: Emporio Armani and
/// Giorgio Armani are one house to anyone deciding what to buy next.
///
/// Keys and values here are ALREADY in normalised form (lowercase, separator
/// free) — `_canonicalBrandKey` looks up post-normalisation.
const Map<String, String> brandAliases = {
  'christiandior': 'dior',
  'parfumschristiandior': 'dior',
  'ysl': 'yvessaintlaurent',
  'saintlaurent': 'yvessaintlaurent',
  'mfk': 'maisonfranciskurkdjian',
  'franciskurkdjian': 'maisonfranciskurkdjian',
  'maisonfrancis': 'maisonfranciskurkdjian',
  'pdm': 'parfumsdemarly',
  'demarly': 'parfumsdemarly',
  'marly': 'parfumsdemarly',
  'jpg': 'jeanpaulgaultier',
  'gaultier': 'jeanpaulgaultier',
  'tomfordprivateblend': 'tomford',
  'tf': 'tomford',
  'dg': 'dolcegabbana',
  'pacorabanne': 'rabanne',
  'thierrymugler': 'mugler',
  'giorgioarmani': 'armani',
  'emporioarmani': 'armani',
  'armaniprive': 'armani',
  'bykilian': 'kilian',
  'kilianparis': 'kilian',
  'bulgari': 'bvlgari',
  'montblanc': 'montblanc',
  'mont': 'montblanc',
  'editionsdeparfumsfredericmalle': 'fredericmalle',
  'editionsdeparfums': 'fredericmalle',
  'malle': 'fredericmalle',
  'marcdelaurent': 'marcdelaurent',
  'marcjacobs': 'marcjacobs',
  'maisonmargiela': 'maisonmargiela',
  'margiela': 'maisonmargiela',
  'mmm': 'maisonmargiela',
  'replica': 'maisonmargiela',
  'jomalonelondon': 'jomalone',
  'penhaligons': 'penhaligons',
  'penhaligon': 'penhaligons',
  'initioparfumsprives': 'initio',
  'initioparfums': 'initio',
  'alharamainperfumes': 'alharamain',
  'lattafaperfumes': 'lattafa',
  'armafperfumes': 'armaf',
  'afnanperfumes': 'afnan',
  'rasasiperfumes': 'rasasi',
  'ajmalperfumes': 'ajmal',
  'swisssarabian': 'swissarabian',
  'alexandriafragrances': 'alexandria',
  'altfragrances': 'alt',
  'dossierco': 'dossier',
  'fragranceone': 'fragranceone',
  'fragone': 'fragranceone',
  'zoologistperfumes': 'zoologist',
  'rojaparfums': 'roja',
  'rojadove': 'roja',
  'clivechristianperfume': 'clivechristian',
  'stephanehumbertlucas': 'shl777',
  'shl': 'shl777',
  '777': 'shl777',
  'lartisanparfumeur': 'lartisan',
  'acquadiparma': 'acquadiparma',
  'carolinaherrera': 'carolinaherrera',
  'ch': 'carolinaherrera',
  'viktorrolf': 'viktorrolf',
  'abercrombiefitch': 'abercrombiefitch',
  'isseymiyake': 'isseymiyake',
  'nishaneistanbul': 'nishane',
  'xerjoffcasamorati': 'xerjoff',
  'casamorati': 'xerjoff',
  'lelabofragrances': 'lelabo',
  'maisonalhambra': 'alhambra',
};

/// Removes diacritics and lowercases. Everything else builds on this.
String foldDiacritics(String input) {
  final buffer = StringBuffer();
  for (final rune in input.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(_diacritics[ch] ?? ch);
  }
  return buffer.toString();
}

/// Lowercased, diacritic-free, punctuation collapsed to single spaces, trimmed.
///
/// The readable intermediate form. Keys go one step further and remove the
/// spaces too — see `_tighten`.
String normaliseLoose(String input) {
  final folded = foldDiacritics(input);
  final buffer = StringBuffer();
  for (final rune in folded.runes) {
    final ch = String.fromCharCode(rune);
    final isAlphaNum =
        (rune >= 0x30 && rune <= 0x39) || (rune >= 0x61 && rune <= 0x7a);
    buffer.write(isAlphaNum ? ch : ' ');
  }
  return buffer
      .toString()
      .split(' ')
      .where(
        (w) =>
            w.isNotEmpty && !_noiseWords.contains(w) && !_volumeToken.hasMatch(w),
      )
      .join(' ');
}

/// A bottle size fused into one token — `100ml`, `3oz`, `50ML`.
///
/// Dropped because the same fragrance is photographed as a 100ml and a 50ml and
/// must not fork into two catalog rows. Bare digits are deliberately NOT
/// dropped: `1 Million`, `No 5`, `212`, `9pm` and `Baccarat Rouge 540` all carry
/// meaning in the number, and stripping those would collapse a house's whole
/// numbered line onto one key.
///
/// Known gap: a size written with a space and a decimal point — `3.4 fl oz` —
/// leaves `3 4` behind, since `fl` and `oz` go as noise words but the digits
/// cannot safely follow them. The identify prompt tells the model to exclude
/// size from the name, so this is a second line of defence rather than the
/// first, and the confirm sheet shows the parsed name before anything is
/// written.
final RegExp _volumeToken = RegExp(r'^\d+(ml|oz)$');

/// The loose form with separators removed. This is what a key is made of.
String _tighten(String loose) => loose.replaceAll(' ', '');

/// Pulls a concentration out of a name, returning the name without it.
///
/// Returns [Concentration.unknown] and the name unchanged when nothing matches,
/// which is the common case for a bottle that does not print its strength.
///
/// Matching is on whole words against the loose form, longest pattern first —
/// so `eau de parfum` wins over the `parfum` inside it. A pattern is only
/// consumed once; `Eau de Parfum` appearing twice (label plus box) still yields
/// one concentration and a clean name.
({String name, Concentration concentration}) extractConcentration(String raw) {
  var loose = normaliseLoose(raw);
  var found = Concentration.unknown;

  for (final (pattern, concentration) in concentrationPatterns) {
    final match = RegExp(
      '(^| )${RegExp.escape(pattern)}( |\$)',
    ).firstMatch(loose);
    if (match == null) continue;

    // Never strip the concentration when it is the ENTIRE name. `Parfum` on its
    // own is Chanel's actual product name for one of its releases, and a name
    // reduced to the empty string would merge with every other Chanel.
    final stripped = loose
        .replaceFirst(RegExp('(^| )${RegExp.escape(pattern)}( |\$)'), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .join(' ');
    if (stripped.isEmpty) break;

    loose = stripped;
    found = concentration;
    break;
  }

  return (name: loose, concentration: found);
}

/// True when two keys differ ONLY by a gender marker.
///
/// Offered to the confirm sheet so a human can collapse `Eros` onto
/// `Eros Pour Homme` — or decline to, because `Aventus` and `Aventus for Her`
/// land here too and they are not the same fragrance. The whole point is that
/// this question goes to a person rather than being answered by a rule.
///
/// Returns false for keys that differ in brand or concentration: those are
/// different rows for reasons that have nothing to do with gendering.
bool genderVariantOf(FragranceKey a, FragranceKey b) {
  if (a.brand != b.brand) return false;
  if (a.concentration != b.concentration) return false;
  if (a.name == b.name) return false;

  final stripped = [a.name, b.name].map(_stripGenderMarkers).toList();
  return stripped[0] == stripped[1] && stripped[0].isNotEmpty;
}

/// Removes gender markers from a TIGHTENED name, for comparison only.
///
/// Never used to build a key — see the comment on [genderPhrases].
String _stripGenderMarkers(String tightName) {
  var out = tightName;
  // Longest first, so `pourhomme` is consumed before the `homme` inside it.
  final phrases = genderPhrases.map((p) => p.replaceAll(' ', '')).toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  for (final phrase in phrases) {
    if (out.length > phrase.length && out.endsWith(phrase)) {
      out = out.substring(0, out.length - phrase.length);
      break;
    }
  }
  return out;
}

/// Resolves a raw brand string to its canonical key.
String canonicalBrandKey(String rawBrand) {
  final tight = _tighten(normaliseLoose(rawBrand));
  return brandAliases[tight] ?? tight;
}

/// A catalog row's identity.
///
/// Two [FragranceKey]s are equal exactly when they name the same fragrance, and
/// `toString` is the stable text form written to the database.
class FragranceKey {
  const FragranceKey({
    required this.brand,
    required this.name,
    required this.concentration,
  });

  /// Canonical brand key — alias-resolved, separator free.
  final String brand;

  /// Canonical name key — brand prefix, concentration and gendering removed,
  /// separator free.
  final String name;

  final Concentration concentration;

  /// The stable text form. Pipe separated because none of the three parts can
  /// contain a pipe after normalisation, so the encoding is unambiguous and
  /// parseable back out.
  String get value => '$brand|$name|${concentration.wire}';

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is FragranceKey &&
      other.brand == brand &&
      other.name == name &&
      other.concentration == concentration;

  @override
  int get hashCode => Object.hash(brand, name, concentration);
}

/// The whole identity pipeline, from what a model read to a catalog key.
///
/// [rawConcentration] is the model's own separate reading of the strength. It
/// WINS over anything found inside the name, because it is a direct observation
/// of the label rather than an inference from wording — but only when it is
/// actually known, so a null or unreadable value still falls back to the name.
///
/// Order matters throughout and each step is justified where it sits.
FragranceKey buildFragranceKey({
  required String rawBrand,
  required String rawName,
  String? rawConcentration,
}) {
  final brand = canonicalBrandKey(rawBrand);

  // 1. Concentration out of the name FIRST, before gendering or the brand
  //    prefix, so `Sauvage Eau de Parfum pour Homme` does not have its
  //    `de`-joined phrase broken up by an earlier removal.
  final extracted = extractConcentration(rawName);

  // 2. The model's explicit reading wins when it has one.
  final declared = _parseDeclaredConcentration(rawConcentration);
  final concentration = declared != Concentration.unknown
      ? declared
      : extracted.concentration;

  // 3. Gendering is deliberately KEPT — see the comment on `genderPhrases`.
  //    Stripping it here would merge Aventus with Aventus for Her.
  var loose = extracted.name;

  // 4. Brand prefix last. Models very often repeat the house inside the name
  //    ("Dior Sauvage" as the name when the brand is already Dior), and just as
  //    often do not — so the two spellings have to converge here or every
  //    fragrance gets two rows depending on how chatty the model was.
  //
  //    Guarded the same way as gendering: `Chanel` the brand with `Chanel` the
  //    whole name must not reduce to nothing.
  loose = _stripBrandPrefix(loose: loose, brandKey: brand);

  return FragranceKey(
    brand: brand,
    name: _tighten(loose),
    concentration: concentration,
  );
}

/// Reads an explicitly-declared concentration string.
///
/// Accepts both the wire values this app emits and the human spellings a model
/// produces when asked for the strength directly.
Concentration _parseDeclaredConcentration(String? raw) {
  if (raw == null || raw.trim().isEmpty) return Concentration.unknown;

  final loose = normaliseLoose(raw);
  if (loose.isEmpty) return Concentration.unknown;

  for (final c in Concentration.values) {
    if (c.wire.replaceAll('_', ' ') == loose) return c;
  }
  for (final (pattern, concentration) in concentrationPatterns) {
    if (loose == pattern) return concentration;
  }
  // A declared value that is a phrase rather than an exact spelling —
  // "eau de parfum intense" reaches here. Fall back to substring matching in
  // the same longest-first order.
  for (final (pattern, concentration) in concentrationPatterns) {
    if (RegExp('(^| )${RegExp.escape(pattern)}( |\$)').hasMatch(loose)) {
      return concentration;
    }
  }
  return Concentration.unknown;
}

/// Removes a leading repetition of the house from a loose name.
///
/// Compares tightened forms so `Yves Saint Laurent Y` matches the
/// `yvessaintlaurent` brand key across its spaces. Only a PREFIX is removed:
/// a house name appearing mid-name ("Dior Homme" under brand Dior) is handled
/// by the prefix rule, but a house name that is genuinely part of the name
/// elsewhere is left alone.
String _stripBrandPrefix({required String loose, required String brandKey}) {
  final words = loose.split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return loose;

  // Walk the prefix, accumulating until it matches the brand key. Handles
  // multi-word houses without needing to know how many words they have.
  var accumulated = '';
  for (var i = 0; i < words.length; i++) {
    accumulated += words[i];
    final resolved = brandAliases[accumulated] ?? accumulated;
    if (accumulated == brandKey || resolved == brandKey) {
      final rest = words.sublist(i + 1);
      // The guard: a name that IS the house keeps its name.
      if (rest.isEmpty) return loose;
      return rest.join(' ');
    }
  }
  return loose;
}
