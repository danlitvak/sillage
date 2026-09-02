// Validator tests — run with:
//   node --experimental-strip-types supabase/functions/_shared/schemas.test.mts
//
// `schemas.ts` is deliberately dependency-free (no Deno globals, no imports) so
// it can be exercised here without a Deno toolchain or a running container.
//
// =============================================================================
// WHAT THESE TESTS ARE ACTUALLY FOR
// =============================================================================
// Every tool sets `strict: true`, so the model cannot return the wrong SHAPE.
// These tests are about the other half: a perfectly-typed response carrying
// nonsense values. A confidence of 12, an empty brand, a `known: false` that
// still ships forty notes. `strict` has no opinion about any of that, and this
// output writes into a catalog shared by every user.
//
// So the assertion throughout is FAIL CLOSED: drop it, clamp it, or reject the
// whole response — never pass it through and hope.

import assert from "node:assert/strict";
import {
  canonicalise,
  cleanModelString,
  validateEnrich,
  validateIdentify,
  validateSuggest,
} from "./schemas.ts";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ok  ${name}`);
  } catch (err) {
    failed++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${(err as Error).message.split("\n")[0]}`);
  }
}

function group(name: string) {
  console.log(`\n${name}`);
}

// =============================================================================
group("identify — structural rejection");

test("a non-object is rejected outright", () => {
  assert.equal(validateIdentify(null).ok, false);
  assert.equal(validateIdentify("candidates").ok, false);
  assert.equal(validateIdentify(42).ok, false);
  assert.equal(validateIdentify([]).ok, false);
});

test("a missing candidates array is rejected, not defaulted to empty", () => {
  // Defaulting would turn a broken response into a silent "couldn't identify
  // it", which reads to the user as the model being useless rather than the
  // parser being broken.
  assert.equal(validateIdentify({ legible: true }).ok, false);
});

test("a missing legible flag is rejected", () => {
  assert.equal(validateIdentify({ candidates: [] }).ok, false);
});

test("an empty candidate list is VALID — it is a real answer", () => {
  const r = validateIdentify({ label_text: "", legible: false, candidates: [] });
  assert.equal(r.ok, true);
  assert.deepEqual(r.ok && r.value.candidates, []);
});

// =============================================================================
group("identify — hostile values inside a well-formed shape");

test("a candidate with no brand is dropped, not written as a partial", () => {
  const r = validateIdentify({
    label_text: "x",
    legible: true,
    candidates: [
      { brand: "", name: "Sauvage", concentration: "edp", confidence: 0.9, reasoning: "" },
      { brand: "Dior", name: "Sauvage", concentration: "edp", confidence: 0.8, reasoning: "" },
    ],
  });
  assert.equal(r.ok, true);
  assert.equal(r.ok && r.value.candidates.length, 1);
  assert.equal(r.ok && r.value.candidates[0].brand, "Dior");
});

test("a candidate with no name is dropped", () => {
  const r = validateIdentify({
    label_text: "x",
    legible: true,
    candidates: [
      { brand: "Dior", name: "   ", concentration: "edp", confidence: 0.9, reasoning: "" },
    ],
  });
  assert.equal(r.ok && r.value.candidates.length, 0);
});

test("an absurd confidence is clamped, not rejected", () => {
  // A number outside 0..1 is the model being sloppy about a scalar, not
  // evidence that the identification itself is wrong.
  const r = validateIdentify({
    label_text: "",
    legible: true,
    candidates: [
      { brand: "Dior", name: "A", concentration: "edp", confidence: 12, reasoning: "" },
      { brand: "Dior", name: "B", concentration: "edp", confidence: -5, reasoning: "" },
    ],
  });
  assert.equal(r.ok, true);
  const cs = r.ok ? r.value.candidates : [];
  assert.equal(cs.find((c) => c.name === "A")!.confidence, 1);
  assert.equal(cs.find((c) => c.name === "B")!.confidence, 0);
});

test("a non-numeric or NaN confidence becomes 0", () => {
  const r = validateIdentify({
    label_text: "",
    legible: true,
    candidates: [
      { brand: "D", name: "A", concentration: "edp", confidence: "high", reasoning: "" },
      { brand: "D", name: "B", concentration: "edp", confidence: NaN, reasoning: "" },
    ],
  });
  const cs = r.ok ? r.value.candidates : [];
  assert.equal(cs.length, 2);
  assert.ok(cs.every((c) => c.confidence === 0));
});

test("an unrecognised concentration degrades to unknown", () => {
  // Never to a guess. The concentration changes the pyramid entirely.
  const r = validateIdentify({
    label_text: "",
    legible: true,
    candidates: [
      { brand: "D", name: "A", concentration: "elixir", confidence: 0.9, reasoning: "" },
    ],
  });
  assert.equal(r.ok && r.value.candidates[0].concentration, "unknown");
});

test("more than three candidates are truncated", () => {
  const r = validateIdentify({
    label_text: "",
    legible: true,
    candidates: Array.from({ length: 10 }, (_, i) => ({
      brand: "D",
      name: `N${i}`,
      concentration: "edp",
      confidence: 0.5,
      reasoning: "",
    })),
  });
  assert.equal(r.ok && r.value.candidates.length, 3);
});

test("candidates are re-ranked here rather than trusting the order given", () => {
  const r = validateIdentify({
    label_text: "",
    legible: true,
    candidates: [
      { brand: "D", name: "low", concentration: "edp", confidence: 0.2, reasoning: "" },
      { brand: "D", name: "high", concentration: "edp", confidence: 0.9, reasoning: "" },
    ],
  });
  assert.equal(r.ok && r.value.candidates[0].name, "high");
});

test("an absurdly long brand or name is dropped", () => {
  const r = validateIdentify({
    label_text: "",
    legible: true,
    candidates: [
      { brand: "D".repeat(500), name: "A", concentration: "edp", confidence: 1, reasoning: "" },
      { brand: "D", name: "A".repeat(500), concentration: "edp", confidence: 1, reasoning: "" },
    ],
  });
  assert.equal(r.ok && r.value.candidates.length, 0);
});

test("label_text is capped rather than stored unbounded", () => {
  const r = validateIdentify({
    label_text: "x".repeat(5000),
    legible: true,
    candidates: [],
  });
  assert.equal(r.ok && r.value.label_text.length, 500);
});

test("a non-string label_text becomes empty, not the literal value", () => {
  const r = validateIdentify({ label_text: { a: 1 }, legible: true, candidates: [] });
  assert.equal(r.ok && r.value.label_text, "");
});

test("garbage entries inside the candidates array are skipped", () => {
  const r = validateIdentify({
    label_text: "",
    legible: true,
    candidates: [
      null,
      "Dior Sauvage",
      42,
      { brand: "Dior", name: "Sauvage", concentration: "edp", confidence: 0.9, reasoning: "" },
    ],
  });
  assert.equal(r.ok && r.value.candidates.length, 1);
});

// =============================================================================
group("enrich — the honesty flag is load-bearing");

test("known:false returns empty arrays EVEN IF notes were supplied", () => {
  // The most important test in this file. A model that sets known:false and
  // then fills the pyramid anyway must not have those notes reach the catalog —
  // they are exactly the invented pyramids the flag exists to prevent.
  const r = validateEnrich({
    known: false,
    release_year: 2015,
    perfumer: "Somebody",
    notes: [
      { name: "Bergamot", tier: "top", position: 0, family: "citrus" },
      { name: "Ambroxan", tier: "base", position: 0, family: "amber" },
    ],
    accords: [{ name: "fresh", weight: 0.9 }],
  });
  assert.equal(r.ok, true);
  assert.equal(r.ok && r.value.known, false);
  assert.deepEqual(r.ok && r.value.notes, []);
  assert.deepEqual(r.ok && r.value.accords, []);
  assert.equal(r.ok && r.value.release_year, null);
  assert.equal(r.ok && r.value.perfumer, null);
});

test("a missing known flag is rejected", () => {
  assert.equal(validateEnrich({ notes: [] }).ok, false);
  assert.equal(validateEnrich(null).ok, false);
});

test("a duplicate note in the same tier is deduped", () => {
  // Letting it through would double that note's weight in the vector.
  const r = validateEnrich({
    known: true,
    release_year: null,
    perfumer: null,
    notes: [
      { name: "Vanilla", tier: "base", position: 0, family: null },
      { name: "vanilla", tier: "base", position: 1, family: null },
    ],
    accords: [],
  });
  assert.equal(r.ok && r.value.notes.length, 1);
});

test("the same note in two tiers is kept — houses really do list it twice", () => {
  const r = validateEnrich({
    known: true,
    release_year: null,
    perfumer: null,
    notes: [
      { name: "Vanilla", tier: "heart", position: 0, family: null },
      { name: "Vanilla", tier: "base", position: 0, family: null },
    ],
    accords: [],
  });
  assert.equal(r.ok && r.value.notes.length, 2);
});

test("an invalid tier degrades to heart rather than dropping the note", () => {
  const r = validateEnrich({
    known: true,
    release_year: null,
    perfumer: null,
    notes: [{ name: "Vanilla", tier: "middle", position: 0, family: null }],
    accords: [],
  });
  assert.equal(r.ok && r.value.notes[0].tier, "heart");
});

test("an out-of-range year becomes null", () => {
  for (const year of [1200, 3000, 20.5, "2015"]) {
    const r = validateEnrich({
      known: true,
      release_year: year,
      perfumer: null,
      notes: [],
      accords: [],
    });
    assert.equal(r.ok && r.value.release_year, null, `year=${year}`);
  }
});

test("a plausible year survives", () => {
  const r = validateEnrich({
    known: true,
    release_year: 2015,
    perfumer: null,
    notes: [],
    accords: [],
  });
  assert.equal(r.ok && r.value.release_year, 2015);
});

test("a negative or oversized note position is clamped", () => {
  const r = validateEnrich({
    known: true,
    release_year: null,
    perfumer: null,
    notes: [
      { name: "A", tier: "top", position: -3, family: null },
      { name: "B", tier: "top", position: 9999, family: null },
    ],
    accords: [],
  });
  const ns = r.ok ? r.value.notes : [];
  assert.equal(ns[0].position, 0);
  assert.equal(ns[1].position, 50);
});

test("accord weights are clamped to 0..1", () => {
  const r = validateEnrich({
    known: true,
    release_year: null,
    perfumer: null,
    notes: [],
    accords: [
      { name: "sweet", weight: 9 },
      { name: "woody", weight: -2 },
    ],
  });
  const as_ = r.ok ? r.value.accords : [];
  assert.equal(as_.find((a) => a.key === "sweet")!.weight, 1);
  assert.equal(as_.find((a) => a.key === "woody")!.weight, 0);
});

test("a runaway note list is capped", () => {
  const r = validateEnrich({
    known: true,
    release_year: null,
    perfumer: null,
    notes: Array.from({ length: 500 }, (_, i) => ({
      name: `Note${i}`,
      tier: "base",
      position: 0,
      family: null,
    })),
    accords: [],
  });
  assert.ok((r.ok ? r.value.notes.length : 0) <= 40);
});

// =============================================================================
group("note canonicalisation");

test("diacritics fold, so one note does not become two", () => {
  assert.equal(canonicalise("Bergamote"), "bergamote");
  assert.equal(canonicalise("Ambrée"), "ambree");
  assert.equal(canonicalise("Fève Tonka"), "feve-tonka");
});

test("case and punctuation do not fork a note", () => {
  assert.equal(canonicalise("Tonka Bean"), canonicalise("tonka  bean"));
  assert.equal(canonicalise("Ylang-Ylang"), canonicalise("Ylang Ylang"));
});

// =============================================================================
group("suggest");

test("duplicate proposals collapse", () => {
  const r = validateSuggest({
    candidates: [
      { brand: "Dior", name: "Sauvage", concentration: "edp", why: "" },
      { brand: "dior", name: "sauvage", concentration: "edp", why: "" },
    ],
  });
  assert.equal(r.ok && r.value.length, 1);
});

test("the same name at a different concentration is NOT a duplicate", () => {
  const r = validateSuggest({
    candidates: [
      { brand: "Dior", name: "Sauvage", concentration: "edp", why: "" },
      { brand: "Dior", name: "Sauvage", concentration: "edt", why: "" },
    ],
  });
  assert.equal(r.ok && r.value.length, 2);
});

test("a runaway candidate list is capped at 15", () => {
  const r = validateSuggest({
    candidates: Array.from({ length: 100 }, (_, i) => ({
      brand: `B${i}`,
      name: `N${i}`,
      concentration: "edp",
      why: "",
    })),
  });
  assert.ok((r.ok ? r.value.length : 0) <= 15);
});

test("a missing candidates array is rejected", () => {
  assert.equal(validateSuggest({}).ok, false);
  assert.equal(validateSuggest(null).ok, false);
});

// =============================================================================
group("tool-call markup leaking into string values (seen in production)");

// The exact payload a user photographed: label_text carrying the closing tag of
// its own parameter and the opening tag of the next, rendered verbatim under
// "READ FROM THE BOTTLE". Assembled from fragments because a literal tag inside
// this source file is itself swallowed by the same serialisation boundary.
const CLOSE_TAG = "<" + "/" + "antml:" + "parameter" + ">";
const OPEN_TAG = "<" + "antml:" + "parameter" + ' name="legible"' + ">";
// String.fromCharCode rather than an escape: this file is written through
// several layers of quoting, and an escaped newline has already been eaten
// once on the way in.
const LEAKED_LABEL = CLOSE_TAG + String.fromCharCode(10) + OPEN_TAG + "false";

test("the leaked label_text is stripped to empty, not shown to the user", () => {
  assert.equal(cleanModelString(LEAKED_LABEL, 500), "");
});

test("a bare trailing JSON literal is dropped too", () => {
  assert.equal(cleanModelString("false", 500), "");
  assert.equal(cleanModelString("  true  ", 500), "");
  assert.equal(cleanModelString("null", 500), "");
});

test("genuine label text with the markup wrapped around it survives", () => {
  assert.equal(cleanModelString("SAUVAGE " + CLOSE_TAG + " Dior", 500), "SAUVAGE Dior");
});

test("the un-namespaced form is stripped as well", () => {
  const open = "<" + "parameter" + ' name="x"' + ">";
  const close = "<" + "/" + "parameter" + ">";
  assert.equal(cleanModelString(open + "Bleu" + close, 500), "Bleu");
});

test("ordinary text is untouched", () => {
  assert.equal(cleanModelString("N°5 CHANEL PARIS EAU DE PARFUM", 500),
    "N°5 CHANEL PARIS EAU DE PARFUM");
});

test("free text is truncated on overflow; identity fields are rejected", () => {
  const long = "x".repeat(50);
  assert.equal(cleanModelString(long, 10).length, 10);
  assert.equal(cleanModelString(long, 10, { overflow: "reject" }), "");
});

test("validateIdentify applies it to label_text", () => {
  const r = validateIdentify({
    label_text: LEAKED_LABEL,
    legible: false,
    candidates: [
      { brand: "Britney Spears", name: "Curious", concentration: "unknown",
        confidence: 0.35, reasoning: "shape" },
    ],
  });
  assert.equal(r.ok, true);
  assert.equal(r.ok && r.value.label_text, "");
  assert.equal(r.ok && r.value.candidates.length, 1);
});

test("and to every candidate string, so a leak cannot become a catalog key", () => {
  const r = validateIdentify({
    label_text: "",
    legible: true,
    candidates: [
      { brand: "Dior" + CLOSE_TAG, name: OPEN_TAG + "Sauvage",
        concentration: "edp", confidence: 0.9, reasoning: CLOSE_TAG },
    ],
  });
  const c = r.ok ? r.value.candidates[0] : undefined;
  assert.equal(c?.brand, "Dior");
  assert.equal(c?.name, "Sauvage");
  assert.equal(c?.reasoning, "");
});

test("enrich note names are cleaned before they become vocabulary", () => {
  const r = validateEnrich({
    known: true, release_year: null, perfumer: CLOSE_TAG,
    notes: [{ name: "Bergamot" + CLOSE_TAG, tier: "top", position: 0, family: null }],
    accords: [],
  });
  assert.equal(r.ok && r.value.notes[0].display_name, "Bergamot");
  assert.equal(r.ok && r.value.notes[0].key, "bergamot");
  assert.equal(r.ok && r.value.perfumer, null);
});

// =============================================================================
console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
