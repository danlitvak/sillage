# Identification eval set

Photographs of bottles whose identity is known, used by
`tool/eval_identify.dart` to measure how well `identify` actually works.

Seven images, all from Wikimedia Commons under free licences — see
[`CREDITS.md`](CREDITS.md). They live in `photos/` and are gitignored: they are
not this project's to redistribute, and the manifest is only useful beside them.

## Ground truth was read off the images, not the filenames

Every entry in `manifest.json` was checked by opening the photograph. That was
not ceremony — **three of the eight originally downloaded were mislabelled by
their Commons filename**:

| filename claimed | the photograph shows |
|---|---|
| `1 Million Parfum` | a gold collector-edition bottle with dice, not the Parfum flanker — **discarded**, ambiguous ground truth |
| `CHANEL No5 parfum` | the label reads `EAU DE PARFUM`, so `edp`, not extrait |
| `Woda toaletowa … 1 Million` | the bottle prints no strength at all, so `unknown` |

An eval set with one wrong label silently corrupts the accuracy number it
produces, which is worse than having no number. If you add images, open them.

## Concentration means "what is legible in this photo"

Several of these bottles do not print their strength anywhere. For those the
expected value is `unknown`, and a model answering `unknown` scores **correct**.

Recording the product's true strength instead would mark the honest answer wrong
and push the prompt toward guessing — the single failure mode the whole
provenance design exists to prevent.

## What is deliberately in the set

- **Sauvage and Eau Sauvage.** Two different Dior fragrances, fifty years apart,
  endlessly confused. The one pair most likely to expose a model matching on
  vibes rather than reading.
- **1 Million and 1 Million Lucky.** A flanker family sharing a bottle shape —
  precisely the case the ranked shortlist exists for.
- **`Christian Dior`** on the Eau Sauvage label, exercising the brand alias.
- **`N°5`**, exercising the degree sign and the `eau de parfum` / `parfum`
  containment ordering.
- **`Acqua di Giò Pour Homme`**, where the gender marker is printed. The harness
  accepts `Acqua di Giò` as a gender variant and reports how many matched that
  way, so the headline number never hides the judgement call.
- **`100 ml 3.3 FL. OZ.` and `Natural Spray`** on the Boss box, exercising volume
  and noise-word stripping.

## The caveat that matters most

**These are clean studio product shots, and that is not what the app receives.**

Real use is a bottle at an angle, in shop lighting, half-reflecting a ceiling
light, sometimes with the label turned away. Accuracy measured on images like
these is a genuine **upper bound**, not an estimate of field performance — it
answers "can the pipeline read a legible label", not "does this work in a shop".

It is still worth running: it is the cheapest way to catch a broken prompt, and
a model that cannot manage these will certainly not manage the real thing. But
the number belongs in a sentence that says which set produced it, and the set
should grow with photographs taken by hand before any claim is made about how
well identification works.

## Running it

```bash
dart run tool/eval_identify.dart --url <supabase-url> --token <access-token>
```

`top-3` is the number that matters — the confirm sheet shows a shortlist and a
person picks from it. `declined` is reported separately and is never counted as
wrong.
