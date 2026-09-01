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
camera renders a synthetic scene and cannot photograph a bottle:

```bash
flutter run -d windows --dart-define=SUPABASE_URL=https://xxxx.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

Tests need no credentials, no device and no network:

```bash
flutter test
```

Edge Function validators (dependency-free TypeScript, run under Node):

```bash
node --experimental-strip-types supabase/functions/_shared/schemas.test.mts
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

---

## What is not done

Stated plainly, because the interesting parts are finished and these are not.

- **No backend has been provisioned.** Migrations, functions and client are
  written; nothing has run against a live Supabase project, so no scan has ever
  completed end to end.
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
