# Architecture

Why the pieces sit where they do. The README says what the app is; this says
what would break if it were arranged differently.

```
Flutter (Android · Windows · web)
  ├── camera / gallery ──► preparePhoto  (native decode, ≤1568px, JPEG)
  └── supabase_flutter ──► Supabase
                             ├── Postgres + RLS   catalog shared, collection per-user
                             ├── Storage          the user's own bottle photos
                             └── Edge Functions ──► Claude
                                   identify · enrich · suggest
                                   the ONLY holder of ANTHROPIC_API_KEY
```

## The dependency rule

`lib/core/` imports **no Flutter, no Supabase, no `dart:io`**. It is plain Dart:
identity normalisation, domain models, the taste profile and the recommender.

That is not tidiness. It is what makes every number the app shows reproducible
in a unit test with a hand-computed expected value, on any machine, with no
device and no network. `flutter test` runs the whole engine in about three
seconds. The moment `core/` imports a Supabase client, that stops being true and
the recommender becomes something you can only check by looking at it.

`lib/data/` is the only layer that knows about Postgres, and it converts at the
boundary.

## Why the API key cannot be in the app

An `ANTHROPIC_API_KEY` compiled into a Flutter build is recoverable with
`strings` on the APK. Every model call therefore goes through a Supabase Edge
Function:

- `verify_jwt` is on, so an anonymous caller cannot spend tokens at all.
- A per-user hourly rate limit is counted **out of the cost ledger itself**
  rather than a separate counter — the ledger already has one row per call, so
  the count cannot disagree with the bill.
- Every response is validated and **fails closed** before anything is written.

The Supabase publishable key *is* shipped in the app, and that is fine: it
identifies the project, and every table is behind RLS.

## Three functions, not one

| | in | out | runs |
|---|---|---|---|
| `identify` | a photograph | ranked candidates + the label text read | every scan |
| `enrich` | one confirmed fragrance | its note pyramid | **at most once per fragrance, ever** |
| `suggest` | a rendered taste profile | a pool of real fragrances | only while the catalog is thin |

The split is economic as much as architectural. `identify` returns three
candidates and the user picks one — generating pyramids for all three would pay
three times for one answer and discard two thirds of it. And because `enrich` is
gated on a catalog miss, the *second* person to scan a bottle of Sauvage costs
nothing and gets the better, possibly human-corrected, pyramid.

That cache only works if the identity key is right, which is why
`lib/core/identity.dart` was built and tested first. A key that forks re-enriches
the same fragrance forever and never accumulates a correction.

## Why the catalog is written through a function

Clients cannot `INSERT` into `fragrances`. There is no insert policy; writes go
through `catalog_propose_fragrance`, a `SECURITY DEFINER` function. Three
problems collapse into one chokepoint:

1. **Vandalism** — the obvious one.
2. **Duplicates.** A client cannot check-then-insert atomically, so two people
   scanning the same new fragrance would race, and the loser would see a unique
   violation that reads as "scanning is broken".
3. **Provenance would be a convention.** The function compares
   `provenance_rank` before replacing a pyramid, so a model pass (rank 1)
   **cannot** overwrite a human correction (rank 3), no matter how many times a
   bottle is rescanned. That is the promise the UI makes when it stops marking a
   pyramid unverified, and it is enforced in the database rather than trusted to
   every future caller.

## Why the model does not rank recommendations

`suggest` names fragrances. It does not score, order, or explain them — its
`why` field is explicitly never shown to a user.

Ranking and explanation happen in `lib/core/recommend.dart`, against IDF-weighted
note vectors. A model asked to both pick and justify produces a fluent paragraph
that cannot be checked against anything; a cosine produces a number, the notes
that drove it, and an explanation that is true by construction — and that a test
can assert.

The three strategies are kept in separate groups on screen rather than merged
into one list, because their scores measure different things. A 0.6 cosine and a
0.6 accord-gap score are not comparable quantities, and one ranked list would
imply an ordering the arithmetic does not support.

## Windows is the development harness

An Android emulator's camera renders a synthetic scene, so identification cannot
be developed or evaluated on one. The Windows target takes a file path in,
exercises the whole pipeline against real photographs, and needs no handset.

This is why `image` replaced `flutter_image_compress` (no Windows
implementation), and why the gallery path in `ScanScreen` is a first-class
control rather than a fallback. Users want it anyway — half the bottles anyone
wants to log are in photos they already took.

## Where the honesty lives

Three mechanisms, because a model that invents note pyramids would corrupt
everything downstream while looking completely normal:

- **`enrich` can decline.** `known: false` is a first-class answer, and the
  validator returns empty arrays even if the model filled them anyway.
- **Provenance is stored per field group** and rendered everywhere, down to the
  shelf tile.
- **The profile reports its own foundations.** When most of a shelf's pyramids
  are unconfirmed, the Taste screen says so — every figure above it was computed
  from them.

## Ported from knockabase

The Edge Functions follow `knockabase/src/app/api/extract/route.ts`, which
learned these branches in production: refusal and truncation handled before
anything indexes into `content`, key-expiry diagnosed by name in the log,
connection failures distinguished from upstream failures, usage recorded on
*every* call including the failures, priced against the **resolved** model id,
and the system prompt split so the cacheable half is a stable prefix.

One difference: knockabase's Haiku default made its cache marker inert (the
prefix was under the 4096-token minimum). Here the model is Opus 5, whose
minimum is 512, and the instruction blocks are well past it — so the marker
actually pays.
