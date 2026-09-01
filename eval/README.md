# Identification eval set

Photographs of bottles whose identity is known, used by
`tool/eval_identify.dart` to measure how well `identify` actually works.

## Why this is not in git

`photos/` and `manifest.json` are gitignored. The photographs are of a personal
collection and there is no reason to publish them; the manifest is only useful
alongside them.

`manifest.example.json` shows the format and is tracked.

## Building a set

Photograph each bottle the way you would actually use the app — in a shop, at an
angle, in bad light, sometimes with the label facing away. A set of clean
studio-lit product shots measures nothing useful, because that is not the input
the app receives.

Include, deliberately:

- **Flanker families.** Several bottles from one line (Sauvage EDT / EDP /
  Parfum / Elixir). This is the case the whole design is built around, and the
  only way to know whether the shortlist is doing its job.
- **Bottles with the label turned away**, to check that the model declines
  rather than guessing from the silhouette.
- **Clone-house bottles**, which are less well represented in training data than
  the designers.
- **At least one fragrance you are confident the model will not know**, to check
  the decline path is reachable at all.

## Reading the result

`top-3` is the number that matters: the confirm sheet shows a shortlist and a
person picks from it, so the right answer being *present* is what makes the
product work. `top-1` measures how often the ordering is also right.

`declined` is reported separately and is **not** counted as a failure. Refusing
to guess is designed behaviour — scoring it as wrong would push the prompt
toward confident invention, which is the failure mode the whole provenance
system exists to prevent.

Expect `concentration` to be the weakest column. It is small type, often
unlit, and frequently absent from the bottle altogether.
