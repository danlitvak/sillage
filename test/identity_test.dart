/// The catalog identity corpus.
///
/// Every case here is a spelling that a vision model plausibly returns from a
/// real bottle or box, paired with another spelling of the same thing — or,
/// just as importantly, of a DIFFERENT thing that looks nearly identical.
///
/// Both directions are tested on purpose. A normalisation suite that only
/// proves things merge will happily pass while merging the entire catalog into
/// one row.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sillage/core/identity.dart';

/// Convenience: build a key from the three strings a model hands back.
FragranceKey key(String brand, String name, [String? concentration]) =>
    buildFragranceKey(
      rawBrand: brand,
      rawName: name,
      rawConcentration: concentration,
    );

void main() {
  group('the pattern list cannot be reordered into a wrong answer', () {
    test('a contained pattern never precedes the pattern containing it', () {
      for (var i = 0; i < concentrationPatterns.length; i++) {
        for (var j = i + 1; j < concentrationPatterns.length; j++) {
          final earlier = concentrationPatterns[i].$1;
          final later = concentrationPatterns[j].$1;
          expect(
            earlier.contains(later) || !later.contains(earlier),
            isTrue,
            reason:
                '"$later" (index $j) contains "$earlier" (index $i), so it '
                'would never be reached — $earlier matches first. Move the '
                'longer pattern earlier in concentrationPatterns.',
          );
        }
      }
    });

    test('eau de parfum beats the parfum inside it', () {
      expect(
        extractConcentration('Sauvage Eau de Parfum').concentration,
        Concentration.edp,
      );
      expect(
        extractConcentration('Baccarat Rouge 540 Extrait de Parfum')
            .concentration,
        Concentration.extrait,
      );
      expect(
        extractConcentration('Eau de Cologne Imperiale').concentration,
        Concentration.edc,
      );
    });

    test('a bare parfum or cologne still reads as itself', () {
      expect(
        extractConcentration('Sauvage Parfum').concentration,
        Concentration.extrait,
      );
      expect(
        extractConcentration('Mugler Cologne').concentration,
        Concentration.edc,
      );
    });

    test('a name that is ONLY a concentration keeps its name', () {
      // Chanel sells a fragrance whose name is the word. Stripping it would
      // leave the empty string, which merges with every other Chanel.
      final result = extractConcentration('Parfum');
      expect(result.name, 'parfum');
      expect(result.concentration, Concentration.unknown);
    });
  });

  group('must merge — one fragrance, many spellings', () {
    final mustMerge = <String, (FragranceKey, FragranceKey)>{
      'house written in full vs short': (
        key('Christian Dior', 'Sauvage EDP'),
        key('Dior', 'Sauvage Eau de Parfum'),
      ),
      'model repeats the house inside the name': (
        key('Dior', 'Dior Sauvage EDP'),
        key('Dior', 'Sauvage Eau de Parfum'),
      ),
      'initialism resolves to the house': (
        key('YSL', 'Y EDP'),
        key('Yves Saint Laurent', 'Y Eau de Parfum'),
      ),
      'diacritics folded on both brand and name': (
        key('Hermès', "Terre d'Hermès"),
        key('Hermes', 'Terre d Hermes'),
      ),
      'apostrophe vs space vs neither': (
        key('YSL', "L'Homme"),
        key('Yves Saint Laurent', 'L Homme'),
      ),
      'apostrophe removed entirely still matches': (
        key('YSL', 'LHomme'),
        key('Yves Saint Laurent', "L'Homme"),
      ),
      'ampersand, the word and, and neither': (
        key('Dolce & Gabbana', 'The One'),
        key('Dolce Gabbana', 'The One'),
      ),
      'the word and is dropped not mapped': (
        key('Dolce and Gabbana', 'The One'),
        key('Dolce & Gabbana', 'The One'),
      ),
      'brand initialism with punctuation': (
        key('D&G', 'The One'),
        key('Dolce & Gabbana', 'The One'),
      ),
      'house rename — Paco Rabanne became Rabanne': (
        key('Paco Rabanne', '1 Million'),
        key('Rabanne', '1Million'),
      ),
      'house rename — Thierry Mugler became Mugler': (
        key('Thierry Mugler', 'Angel'),
        key('Mugler', 'Angel'),
      ),
      'sub-line folds into the parent house': (
        key('Giorgio Armani', 'Acqua di Gio'),
        key('Armani', 'Acqua di Giò'),
      ),
      'four-letter initialism': (
        key('MFK', 'Baccarat Rouge 540 Extrait'),
        key(
          'Maison Francis Kurkdjian',
          'Baccarat Rouge 540 Extrait de Parfum',
        ),
      ),
      'lowercase initialism for a multi-word house': (
        key('PdM', 'Layton'),
        key('Parfums de Marly', 'Layton'),
      ),
      'two-letter house initialism': (
        key('TF', 'Tobacco Vanille'),
        key('Tom Ford', 'Tobacco Vanille'),
      ),
      'brand prefix repeated, no concentration anywhere': (
        key('Creed', 'Creed Aventus'),
        key('Creed', 'Aventus'),
      ),
      'By Kilian and Kilian are one house': (
        key('By Kilian', "Angels' Share"),
        key('Kilian', 'Angels Share'),
      ),
      'Margiela line name folds to the house': (
        key('Maison Margiela', 'Replica Jazz Club'),
        key('Margiela', 'Replica Jazz Club'),
      ),
      'degree sign, abbreviation and spaced number all agree': (
        key('Chanel', 'N°5 EDP'),
        key('Chanel', 'No. 5 Eau de Parfum'),
      ),
      'bottle size does not fork the row': (
        key('Lattafa', 'Khamrah 100ml Spray'),
        key('Lattafa', 'Khamrah'),
      ),
      'packaging noise words dropped': (
        key('Versace', 'Eros Natural Spray'),
        key('Versace', 'Eros'),
      ),
      'declared concentration beats a silent name': (
        key('Dior', 'Sauvage', 'Eau de Parfum'),
        key('Dior', 'Sauvage EDP'),
      ),
      'declared concentration as a wire value': (
        key('Dior', 'Sauvage', 'edp'),
        key('Dior', 'Sauvage Eau de Parfum'),
      ),
      'declared phrase with a marketing suffix still reads': (
        key('Dior', 'Sauvage', 'Eau de Parfum Intense'),
        key('Dior', 'Sauvage EDP'),
      ),
      'case and stray punctuation are irrelevant': (
        key('CHANEL', 'BLEU DE CHANEL -- eau de parfum'),
        key('Chanel', 'Bleu de Chanel EDP'),
      ),
    };

    mustMerge.forEach((label, pair) {
      test(label, () {
        expect(
          pair.$1,
          pair.$2,
          reason:
              'these are the same fragrance and must share a catalog row\n'
              '  ${pair.$1.value}\n  ${pair.$2.value}',
        );
        // Equality and the stored text form must not disagree — the database
        // keys on `value`, so a mismatch here is a split that the Dart-level
        // tests would never see.
        expect(pair.$1.value, pair.$2.value);
      });
    });
  });

  group('must NOT merge — near-identical names, different fragrances', () {
    final mustNotMerge = <String, (FragranceKey, FragranceKey)>{
      'concentration is the only difference and it is enough': (
        key('Dior', 'Sauvage EDT'),
        key('Dior', 'Sauvage EDP'),
      ),
      'a flanker is not its original': (
        key('Versace', 'Eros Flame'),
        key('Versace', 'Eros'),
      ),
      'the feminine counterpart is a different fragrance': (
        key('Creed', 'Aventus for Her'),
        key('Creed', 'Aventus'),
      ),
      'so is the masculine one': (
        key('Armani', 'Armani Code Pour Femme'),
        key('Armani', 'Armani Code Pour Homme'),
      ),
      'same name, different house': (
        key('Lattafa', 'Asad'),
        key('Armaf', 'Asad'),
      ),
      'two fragrances from one house': (
        key('Chanel', 'Bleu de Chanel EDP'),
        key('Chanel', 'No 5 EDP'),
      ),
      'a numbered line does not collapse': (
        key('Xerjoff', 'Erba Pura'),
        key('Xerjoff', 'Naxos'),
      ),
      'Extrait and EDP of the same name stay apart': (
        key('MFK', 'Baccarat Rouge 540 Extrait de Parfum'),
        key('MFK', 'Baccarat Rouge 540 Eau de Parfum'),
      ),
      'unknown concentration is its own bucket, not a wildcard': (
        key('Dior', 'Sauvage'),
        key('Dior', 'Sauvage EDP'),
      ),
    };

    mustNotMerge.forEach((label, pair) {
      test(label, () {
        expect(
          pair.$1,
          isNot(pair.$2),
          reason:
              'these are DIFFERENT fragrances and must not share a row\n'
              '  ${pair.$1.value}\n  ${pair.$2.value}',
        );
      });
    });
  });

  group('marketing words stay in the name and are not strengths', () {
    // ------------------------------------------------------------------
    // These assert the PARSE, not merely that two keys differ.
    //
    // An earlier version of this suite only checked that `Sauvage Elixir`
    // and `Sauvage EDP` landed on different rows — and a deliberate mutation
    // adding `('elixir', Concentration.extrait)` to concentrationPatterns
    // passed it, because the keys still differed (extrait vs edp) for the
    // wrong reason. Asserting the name and the concentration is what actually
    // pins the behaviour.
    // ------------------------------------------------------------------
    const marketingWords = ['Elixir', 'Intense', 'Absolu', 'Extreme', 'Profumo'];

    for (final word in marketingWords) {
      test('$word stays in the name and yields no concentration', () {
        final result = extractConcentration('Sauvage $word');
        expect(
          result.name,
          'sauvage ${word.toLowerCase()}',
          reason:
              '"$word" was stripped out of the name — it is a product name, '
              'not a concentration. See judgement call 3 in identity.dart.',
        );
        expect(
          result.concentration,
          Concentration.unknown,
          reason: '"$word" must not be read as a strength.',
        );
      });
    }

    test('Sauvage Elixir keeps elixir in its catalog key', () {
      final k = key('Dior', 'Sauvage Elixir');
      expect(k.name, 'sauvageelixir');
      expect(k.concentration, Concentration.unknown);
    });

    test('Dior Homme Intense keeps intense in its catalog key', () {
      final k = key('Dior', 'Dior Homme Intense');
      expect(k.name, 'hommeintense');
      expect(k.concentration, Concentration.unknown);
    });

    test('and they still do not merge with the base fragrance', () {
      expect(key('Dior', 'Sauvage Elixir'), isNot(key('Dior', 'Sauvage EDP')));
      expect(key('Dior', 'Dior Homme Intense'), isNot(key('Dior', 'Dior Homme')));
    });

    test('an Elixir at a declared strength keeps both facts', () {
      // The one case where both are genuinely present on the label.
      final k = key('Dior', 'Sauvage Elixir', 'Eau de Parfum');
      expect(k.name, 'sauvageelixir');
      expect(k.concentration, Concentration.edp);
    });
  });

  group('gender variants are suggested, never merged', () {
    test('Eros and Eros Pour Homme are separate rows', () {
      final plain = key('Versace', 'Eros', 'EDT');
      final gendered = key('Versace', 'Eros Pour Homme', 'EDT');
      expect(plain, isNot(gendered));
    });

    test('but they are offered to the confirm sheet as a possible match', () {
      final plain = key('Versace', 'Eros', 'EDT');
      final gendered = key('Versace', 'Eros Pour Homme', 'EDT');
      expect(genderVariantOf(plain, gendered), isTrue);
      expect(genderVariantOf(gendered, plain), isTrue);
    });

    test('Aventus and Aventus for Her are offered too — a human declines', () {
      // The documented cost of suggesting rather than merging: this pair
      // surfaces as a question, and the right answer is "no". A rule that
      // merged them automatically would be silently wrong instead.
      expect(
        genderVariantOf(key('Creed', 'Aventus'), key('Creed', 'Aventus for Her')),
        isTrue,
      );
    });

    test('a different concentration is never a gender variant', () {
      expect(
        genderVariantOf(
          key('Versace', 'Eros', 'EDT'),
          key('Versace', 'Eros Pour Homme', 'EDP'),
        ),
        isFalse,
      );
    });

    test('a different house is never a gender variant', () {
      expect(
        genderVariantOf(key('Versace', 'Eros'), key('Lattafa', 'Eros Pour Homme')),
        isFalse,
      );
    });

    test('unrelated names are not gender variants', () {
      expect(
        genderVariantOf(key('Dior', 'Sauvage'), key('Dior', 'Fahrenheit')),
        isFalse,
      );
    });
  });

  group('guards against reducing a name to nothing', () {
    test('Dior Homme keeps its name when the brand prefix is stripped', () {
      // "Dior Homme" under brand Dior must become "homme", not "".
      final k = key('Dior', 'Dior Homme');
      expect(k.name, 'homme');
      expect(k.name, isNotEmpty);
    });

    test('a name identical to the house survives', () {
      final k = key('Chanel', 'Chanel');
      expect(k.name, isNotEmpty);
    });

    test('a name that is only a concentration survives', () {
      final k = key('Chanel', 'Parfum');
      expect(k.name, isNotEmpty);
    });
  });

  group('brand resolution', () {
    test('an unknown house passes through rather than erroring', () {
      expect(canonicalBrandKey('Some New Indie House'), 'somenewindiehouse');
    });

    test('aliases are applied after normalisation, not before', () {
      // "Y.S.L." only becomes "ysl" after punctuation is collapsed, so an
      // alias table consulted too early would miss it.
      expect(canonicalBrandKey('Y.S.L.'), 'yvessaintlaurent');
      expect(canonicalBrandKey('y s l'), 'yvessaintlaurent');
    });

    test('diacritics are folded before the alias lookup', () {
      expect(canonicalBrandKey('Hermès'), 'hermes');
    });
  });

  group('the wire form round-trips', () {
    test('value is stable, parseable and pipe-free in every part', () {
      final k = key('Christian Dior', 'Sauvage Eau de Parfum');
      expect(k.value, 'dior|sauvage|edp');
      expect(k.brand, isNot(contains('|')));
      expect(k.name, isNot(contains('|')));
    });

    test('concentration wire values survive a round trip', () {
      for (final c in Concentration.values) {
        expect(Concentration.fromWire(c.wire), c);
      }
    });

    test('an unrecognised wire value degrades to unknown, not a crash', () {
      expect(Concentration.fromWire('eau_de_something'), Concentration.unknown);
      expect(Concentration.fromWire(null), Concentration.unknown);
    });
  });
}
