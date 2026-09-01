# sillage

Photograph a fragrance bottle, have it identified, and it lands on your shelf.
Tap into any bottle for its note pyramid. Once the shelf is real, get
recommendations that key off *how you actually buy* — clones versus designers,
loyalty to one house, the one note you keep chasing.

*Sillage* is the trail a fragrance leaves behind.

**Flutter** (Android · Windows · web) · **Supabase** Postgres + RLS + Storage ·
**Claude** behind three Edge Functions.

---

## The three problems that decide whether this works

Everything else is CRUD.

### 1. Bottle photographs are ambiguous by construction

Houses reuse one bottle across a whole line. Sauvage EDT, EDP, Parfum and Elixir
are the same glass with a different cap and one different word on the label.
Flankers are the norm.

So the signal is the **label text**, not the silhouette — and `identify` is
asked for a **ranked shortlist with the evidence it read**, not one confident
answer. The ambiguity survives to the confirm sheet, where it is resolved by
someone holding the bottle. Nothing is written until they pick.

Returning *no* candidates is a valid answer and a designed outcome.

### 2. Catalog identity — the same trap as knockabase's doors

`Dior Sauvage EDP` must resolve to one row whether the model says
`Christian Dior`, `Dior` or `DIOR`, and whether the name arrives as
`Sauvage Eau de Parfum` or `Sauvage` + `EDP`. Too loose and two fragrances merge;
too tight and one fragrance forks. **Both fail silently.**

[`lib/core/identity.dart`](lib/core/identity.dart) is the whole answer, and it
was written and tested before anything was allowed to write to the catalog.
Three judgement calls are stated in the file header — the space-free key, the
dropped `&`, and `Elixir`/`Intense` staying in the *name* rather than being read
as strengths.

One rule earns its own mention: **gender markers are deliberately NOT stripped.**
The first version dropped them, which correctly merged `Eros Pour Homme` with
`Eros` — and also merged **Creed Aventus with Aventus for Her**. Suggest, never
merge.

### 3. Notes provenance

A note pyramid is exactly the kind of thing a model confabulates fluently, and
every recommendation is computed from these notes. So every catalog field
carries where it came from — `user` > `brand` > `model` — the precedence is
enforced *in Postgres*, not by convention, and an unconfirmed pyramid is visibly
marked everywhere it appears, down to the shelf tile.

`enrich` gives the model an explicit way to say **"I do not know this one"**, and
the prompt makes declining the expected behaviour for anything obscure. An
admitted unknown is a normal outcome the app handles.

---

## The recommender

**The model proposes candidates. Deterministic Dart decides and explains.**

That split is the point. A model asked to both pick and justify produces a
fluent paragraph that cannot be checked against anything. A cosine over an
IDF-weighted note vocabulary produces a number, the notes that drove it, and an
explanation that is true by construction.

- **Note vectors** — `tier_weight × idf`, base 1.0 / heart 0.7 / top 0.4,
  because base notes are what you smell for six hours and top notes are gone in
  fifteen minutes. IDF is smoothed so a ubiquitous note counts for *little*
  rather than *nothing*.
- **Detectors** with stated thresholds: clone buyer, house loyalist, note
  obsession, accord gap, tier concentration — plus one that reports how much of
  the profile rests on unverified data.
- **Three strategies**, each with its own explanation: nearest neighbour, gap
  filling, and pattern-driven (*"you own four Aventus clones — here's the
  original"*).

Nothing fires below four bottles. Detectors on a three-bottle shelf are noise
dressed as insight.

---

## Running it

```bash
flutter pub get
```

Development happens on the **Windows target**, because an Android emulator's
camera renders a synthetic scene and cannot photograph a bottle. Windows plugin
builds need Developer Mode on (`start ms-settings:developers`) for symlink
support.

Bring up the local stack — migrations and a seeded shelf apply automatically:

```bash
supabase start
```

Then run against it:

```bash
flutter run -d windows --dart-define=SUPABASE_URL=http://127.0.0.1:54321 --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH
```

The seed creates `dev@sillage.local` / `sillage123` with seven bottles on the
shelf. Sign in with the password form: **magic link cannot complete on a desktop
build**, because a browser has no way to hand the session back without a
registered URI scheme.

Tests need no credentials, no device and no network:

```bash
flutter test
```

Edge Function validators (dependency-free TypeScript, run under Node):

```bash
node --experimental-strip-types supabase/functions/_shared/schemas.test.mts
```

And an end-to-end check of everything except identification, against the running
local stack — real auth, the real selects, the real recommender, no GUI:

```bash
dart run tool/check_recommender.dart
```

### Backend

```bash
supabase link --project-ref <ref>
supabase db push
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
supabase functions deploy identify enrich suggest
```

The Anthropic key lives **only** in function secrets. A key compiled into the
app is extractable from the APK in about thirty seconds, which is why every
model call goes through an Edge Function with `verify_jwt` on and a per-user
rate limit counted out of the cost ledger itself.

---

## Tests

**132 Dart tests + 31 TypeScript validator tests.**

| Suite | What it pins |
|---|---|
| [`identity_test.dart`](test/identity_test.dart) | 62 cases, **both directions** — must-merge *and* must-not-merge. A suite that only proves things merge passes happily while merging the whole catalog into one row. |
| [`taste_test.dart`](test/taste_test.dart) | Hand-computed vectors, IDF values and detector thresholds. Pure, no I/O. |
| [`viewport_test.dart`](test/viewport_test.dart) | Nine viewports, from a 320px phone to a 240px-wide desktop window. |
| [`schemas.test.mts`](supabase/functions/_shared/schemas.test.mts) | Hostile model output — every validator fails closed. |

Three deliberate mutations were run against the identity suite to check it has
teeth: treating `Elixir` as a concentration (3 failures), breaking the
containment ordering so `parfum` matches before `eau de parfum` (11), and
re-enabling gender stripping (9). The first mutation initially **passed** — the
Elixir test only asserted the two keys differed, which stayed true for the wrong
reason. That test now asserts the parse.

The TypeScript suite caught a real bug on its first run: candidates were
truncated to three *before* validation, so a response of
`[null, "text", 42, {a good candidate}]` yielded nothing at all.

### Measured: identification

Against the 7-image set in `eval/` (`tool/eval_identify.dart`, `claude-opus-5`),
with each photo resized to the same 1568px bound the app applies:

| | |
|---|---|
| top-1 | **7/7** |
| top-3 | **7/7** |
| brand | **7/7** |
| concentration | **7/7** — 3 read off the label, 4 correctly answered `unknown` |
| declined to guess | 0 |
| cost | **$0.016 per scan** (12,194 in / 2,086 out over 7 scans; 140 KB uploaded each) |

**The first run scored 6/7, and the miss was my labelling error, not the
model's.** I had written the Boss ground truth as `Bottled`; the model returned
`Boss Bottled`, which is what the box says and what the house calls it. The
manifest is corrected and the correction is recorded in `eval/manifest.json` —
worth knowing when reading the 7/7, because the number moved by fixing the test,
not the code.

Both designed traps passed:

- **Eau Sauvage** was not confused with Sauvage, and came back as a *shortlist*
  of its own flanker family (Eau Sauvage / Parfum / Extreme) at a modest 0.60
  top confidence — the ambiguity surviving to the confirm sheet, exactly as
  intended.
- **1 Million Lucky** was not confused with 1 Million; the model read
  `1 MILLION / LUCKY / 50 ml 1.7 fl.oz / paco rabanne` off the bottle.
- Brand aliasing did real work: `Christian Dior` and `Paco Rabanne` came back
  from the model and normalised to `dior` and `rabanne`.

**What this number is not.** Seven images, all clean studio product shots. Real
use is a bottle at an angle in shop lighting with the label half-turned away.
This says the pipeline reads a legible label correctly and that the prompt is
not broken; it says nothing yet about field performance, and the `declined`
column has never been exercised because every one of these was legible.

### Verified against a live database

The migrations were applied to a local Supabase stack and the security-critical
behaviour exercised directly, because none of it is reachable from a Dart test:

| Checked | Result |
|---|---|
| A human correction survives a later model rescan | source stays `user`, 3 notes kept, the rescan's `vanilla` never lands |
| Three proposals of one fragrance | one row, one id — the cache that makes `enrich` run once per fragrance |
| A note alias resolves instead of forking the vocabulary | same note id returned |
| A second user reading the first user's collection | 0 rows |
| A second user writing a row owned by the first | `new row violates row-level security policy` |
| A client `INSERT` straight into the catalog | `permission denied for table fragrances` |
| The catalog itself, across users | shared and readable, as intended |

`tool/check_recommender.dart` re-runs the read path, the profile and the
recommender against that stack on demand, and would catch the PostgREST column
list drifting from the row mapper — which no unit test would.

That run found a real bug that no unit test could: **RLS policies alone do not
grant table access.** Every table had RLS and policies and no `GRANT`, so the
first real read failed with `permission denied for table fragrances` — the
policies were never even consulted. Grants are now explicit in
`20260831120000_init.sql`, scoped narrowly (the catalog is SELECT-only for
clients; `llm_usage` is read-only so a client cannot forge or erase its own cost
record).

---

## What is not done

Stated plainly, because the interesting parts are finished and these are not.

- **No hosted backend.** Everything runs against `supabase start`. Nothing is
  deployed, so the app has never run anywhere but this machine.
- **Accuracy is measured on 7 clean studio photographs, which is an upper
  bound** — see below. No photograph taken by hand has ever gone through it.
- **The clone table has 2 hand-written edges.** Enough to prove the strategy;
  nowhere near a useful seed.
- **Identification accuracy is unmeasured.** The harness exists
  ([`tool/eval_identify.dart`](tool/eval_identify.dart), graded through the same
  normalisation the app uses) but needs a photo set. Until it runs, this README
  makes no accuracy claim and neither should anything else.
- **Windows builds need Developer Mode.** Flutter plugins require symlink
  support; `flutter test` and the whole core are unaffected.
- **The clone table is empty.** `clone_of` is designed for a hand-curated seed of
  well-known pairs; none are seeded yet, so the clone detector cannot fire.
- **No CI**, and no git remote.

---

## Layout

```
lib/core/          pure Dart — identity, models, taste, recommender. No Flutter,
                   no Supabase, no network. The whole engine is unit-testable.
lib/data/          Supabase access, the scan pipeline, image preparation.
lib/features/      one folder per screen.
lib/theme/         the house style, lifted from calculus-lab-app.
supabase/          migrations, and the three Edge Functions.
tool/              the identification eval harness.
```

The house style — monochrome zinc, square corners, JetBrains Mono headings —
comes from [`Dev/DESIGN.md`](../DESIGN.md). Widgets in
[`lib/widgets/common.dart`](lib/widgets/common.dart) each cite the rule they
exist to enforce.
