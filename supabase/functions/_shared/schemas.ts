// Tool schemas and their validators.
//
// =============================================================================
// TWO LAYERS, ON PURPOSE
// =============================================================================
// Every tool below sets `strict: true`, which compiles the schema into a
// constrained decoder — the model cannot emit a shape that violates it. And
// every response is STILL validated here before anything is written.
//
// That is not redundant. `strict` guarantees the JSON matches the schema; it
// guarantees nothing about whether the values are sane. A model can return a
// perfectly-typed candidate with an empty brand, a confidence of 12, or forty
// notes, and the schema has no opinion about any of that. This layer does, and
// it fails closed — these responses write into a SHARED catalog, where a bad
// row is visible to every future scan of the same bottle.

// =============================================================================
// IDENTIFY
// =============================================================================

/** Concentration values the model may return — mirrors Concentration.wire. */
export const CONCENTRATIONS = [
  "extrait",
  "edp",
  "edt",
  "edc",
  "eau_fraiche",
  "oil",
  "unknown",
] as const;

export const identifyTool = {
  name: "report_candidates",
  description:
    "Report what is legible on the fragrance bottle in the photograph, and the " +
    "ranked candidates it could be. Call exactly once.",
  strict: true,
  input_schema: {
    type: "object" as const,
    properties: {
      label_text: {
        type: "string",
        description:
          "Every word you can actually READ on the bottle, box or cap, " +
          "verbatim and in the order it appears, including text you cannot " +
          "interpret. Empty string if nothing is legible. This is shown to the " +
          "user as the evidence behind your candidates, so it must be what is " +
          "really printed rather than what you infer the product to be.",
      },
      legible: {
        type: "boolean",
        description:
          "True only if you could read actual text off the bottle. False when " +
          "you are working from bottle shape, colour or cap alone.",
      },
      candidates: {
        type: "array",
        description:
          "Up to 3 candidates, most likely first. Empty array if you genuinely " +
          "cannot tell — an empty list is a valid and useful answer, and far " +
          "better than a guess the user has to notice is wrong.",
        items: {
          type: "object",
          properties: {
            brand: {
              type: "string",
              description: "The house, as it is written on the bottle. e.g. 'Dior'.",
            },
            name: {
              type: "string",
              description:
                "The fragrance name WITHOUT the house and WITHOUT the bottle " +
                "size. Keep words like Elixir, Intense, Absolu and Extreme — " +
                "they are part of the name and identify a different product. " +
                "e.g. 'Sauvage Elixir'.",
            },
            concentration: {
              type: "string",
              enum: CONCENTRATIONS,
              description:
                "The strength printed on the label. Use 'unknown' when it is " +
                "not printed or not legible — this is common and expected. Do " +
                "NOT infer it from the bottle or from which release is most " +
                "popular: the concentration changes the note pyramid entirely, " +
                "so a guess here is worse than an admission.",
            },
            confidence: {
              type: "number",
              description:
                "0 to 1. How sure you are that this specific candidate is the " +
                "bottle in the photograph.",
            },
            reasoning: {
              type: "string",
              description:
                "One short sentence naming what in the image supports this " +
                "candidate — the text read, the cap colour, the bottle shape.",
            },
          },
          required: ["brand", "name", "concentration", "confidence", "reasoning"],
          additionalProperties: false,
        },
      },
    },
    required: ["label_text", "legible", "candidates"],
    additionalProperties: false,
  },
};

export interface Candidate {
  brand: string;
  name: string;
  concentration: string;
  confidence: number;
  reasoning: string;
}

export interface IdentifyResult {
  label_text: string;
  legible: boolean;
  candidates: Candidate[];
}

/** Ceiling on candidates KEPT, applied after validation — see below. */
const MAX_CANDIDATES = 3;

/**
 * Ceiling on candidates EXAMINED. Bounds the work a hostile response can cause
 * without letting junk entries consume the kept slots.
 *
 * These are two different limits and conflating them was a real bug: truncating
 * to 3 before validating meant a response of `[null, "text", 42, {a good
 * candidate}]` yielded nothing at all, because the three junk entries ate every
 * slot before the valid one was reached. Validate first, rank, then keep.
 */
const MAX_CANDIDATES_EXAMINED = 20;

export function validateIdentify(
  raw: unknown,
): { ok: true; value: IdentifyResult } | { ok: false; reason: string } {
  if (typeof raw !== "object" || raw === null) {
    return { ok: false, reason: "not an object" };
  }
  const o = raw as Record<string, unknown>;

  if (typeof o.legible !== "boolean") return { ok: false, reason: "legible missing" };
  if (!Array.isArray(o.candidates)) return { ok: false, reason: "candidates missing" };

  const labelText = typeof o.label_text === "string" ? o.label_text.slice(0, 500) : "";

  const candidates: Candidate[] = [];
  for (const item of o.candidates.slice(0, MAX_CANDIDATES_EXAMINED)) {
    if (typeof item !== "object" || item === null) continue;
    const c = item as Record<string, unknown>;

    const brand = typeof c.brand === "string" ? c.brand.trim() : "";
    const name = typeof c.name === "string" ? c.name.trim() : "";
    // A candidate missing either half cannot produce a catalog key, so it is
    // dropped rather than written as a partial row.
    if (!brand || !name) continue;
    if (brand.length > 120 || name.length > 200) continue;

    const concentration =
      typeof c.concentration === "string" &&
      (CONCENTRATIONS as readonly string[]).includes(c.concentration)
        ? c.concentration
        : "unknown";

    // Clamped, not rejected: a confidence outside 0..1 is the model being
    // sloppy about a number, not evidence the identification is wrong.
    const rawConfidence = typeof c.confidence === "number" ? c.confidence : 0;
    const confidence = Number.isFinite(rawConfidence)
      ? Math.min(1, Math.max(0, rawConfidence))
      : 0;

    candidates.push({
      brand,
      name,
      concentration,
      confidence,
      reasoning: typeof c.reasoning === "string" ? c.reasoning.slice(0, 300) : "",
    });
  }

  // Ranked here rather than trusting the model's ordering — the contract says
  // "most likely first" and this makes it true. Only THEN truncated, so the
  // three kept are the three best that survived validation.
  candidates.sort((a, b) => b.confidence - a.confidence);

  return {
    ok: true,
    value: {
      label_text: labelText,
      legible: o.legible,
      candidates: candidates.slice(0, MAX_CANDIDATES),
    },
  };
}

// =============================================================================
// ENRICH — the note pyramid for ONE confirmed fragrance
// =============================================================================
// Split from identify deliberately. Generating pyramids for three candidates
// when two get discarded is paying three times for one answer, and the catalog
// caches the result, so this runs at most once per fragrance ever.

export const NOTE_TIERS = ["top", "heart", "base"] as const;

export const enrichTool = {
  name: "report_pyramid",
  description:
    "Report the note pyramid and accords for one named fragrance. Call exactly once.",
  strict: true,
  input_schema: {
    type: "object" as const,
    properties: {
      known: {
        type: "boolean",
        description:
          "False if you do not actually know this fragrance. Say so rather " +
          "than composing a plausible pyramid — an unknown fragrance is a " +
          "normal outcome and the app handles it, whereas invented notes are " +
          "shown to the user as fact and poison every recommendation computed " +
          "from them.",
      },
      release_year: { type: ["integer", "null"] },
      perfumer: { type: ["string", "null"] },
      notes: {
        type: "array",
        description:
          "The pyramid. Only notes the house actually lists. Empty if unknown.",
        items: {
          type: "object",
          properties: {
            name: { type: "string", description: "e.g. 'Bergamot'." },
            tier: { type: "string", enum: NOTE_TIERS },
            position: {
              type: "integer",
              description: "0-based position within the tier, as the house lists it.",
            },
            family: {
              type: ["string", "null"],
              description: "Coarse family, e.g. 'citrus', 'woody', 'amber'.",
            },
          },
          required: ["name", "tier", "position", "family"],
          additionalProperties: false,
        },
      },
      accords: {
        type: "array",
        items: {
          type: "object",
          properties: {
            name: { type: "string" },
            weight: { type: "number", description: "0 to 1." },
          },
          required: ["name", "weight"],
          additionalProperties: false,
        },
      },
    },
    required: ["known", "release_year", "perfumer", "notes", "accords"],
    additionalProperties: false,
  },
};

export interface EnrichedNote {
  key: string;
  display_name: string;
  tier: string;
  position: number;
  family: string | null;
}

export interface EnrichResult {
  known: boolean;
  release_year: number | null;
  perfumer: string | null;
  notes: EnrichedNote[];
  accords: { key: string; display_name: string; weight: number }[];
}

/** Canonical key for a note or accord name. Mirrors normaliseLoose in Dart. */
export function canonicalise(name: string): string {
  return name
    .toLowerCase()
    .normalize("NFD")
    // Strip combining marks, so "Calabrian Bergamot" and "Bergamot" fold the
    // same way the Dart side folds them.
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, "-");
}

const MAX_NOTES = 40;

export function validateEnrich(
  raw: unknown,
): { ok: true; value: EnrichResult } | { ok: false; reason: string } {
  if (typeof raw !== "object" || raw === null) {
    return { ok: false, reason: "not an object" };
  }
  const o = raw as Record<string, unknown>;
  if (typeof o.known !== "boolean") return { ok: false, reason: "known missing" };

  // An admitted unknown short-circuits: no notes are read, so none can leak
  // through from a model that filled the array anyway.
  if (!o.known) {
    return {
      ok: true,
      value: {
        known: false,
        release_year: null,
        perfumer: null,
        notes: [],
        accords: [],
      },
    };
  }

  const year =
    typeof o.release_year === "number" &&
    Number.isInteger(o.release_year) &&
    o.release_year >= 1700 &&
    o.release_year <= 2100
      ? o.release_year
      : null;

  const notes: EnrichedNote[] = [];
  const seen = new Set<string>();
  if (Array.isArray(o.notes)) {
    for (const item of o.notes.slice(0, MAX_NOTES)) {
      if (typeof item !== "object" || item === null) continue;
      const n = item as Record<string, unknown>;
      const display = typeof n.name === "string" ? n.name.trim() : "";
      if (!display || display.length > 80) continue;
      const tier =
        typeof n.tier === "string" && (NOTE_TIERS as readonly string[]).includes(n.tier)
          ? n.tier
          : "heart";
      const key = canonicalise(display);
      if (!key) continue;
      // One note per tier. A duplicate is a model slip, and letting it through
      // would double that note's weight in the vector.
      const dedupeKey = `${key}|${tier}`;
      if (seen.has(dedupeKey)) continue;
      seen.add(dedupeKey);

      const position =
        typeof n.position === "number" && Number.isFinite(n.position)
          ? Math.min(50, Math.max(0, Math.trunc(n.position)))
          : 0;

      notes.push({
        key,
        display_name: display,
        tier,
        position,
        family: typeof n.family === "string" && n.family.trim()
          ? canonicalise(n.family)
          : null,
      });
    }
  }

  const accords: EnrichResult["accords"] = [];
  const seenAccords = new Set<string>();
  if (Array.isArray(o.accords)) {
    for (const item of o.accords.slice(0, 12)) {
      if (typeof item !== "object" || item === null) continue;
      const a = item as Record<string, unknown>;
      const display = typeof a.name === "string" ? a.name.trim() : "";
      if (!display || display.length > 60) continue;
      const key = canonicalise(display);
      if (!key || seenAccords.has(key)) continue;
      seenAccords.add(key);
      const w = typeof a.weight === "number" && Number.isFinite(a.weight) ? a.weight : 0.5;
      accords.push({
        key,
        display_name: display,
        weight: Math.min(1, Math.max(0, w)),
      });
    }
  }

  return {
    ok: true,
    value: {
      known: true,
      release_year: year,
      perfumer:
        typeof o.perfumer === "string" && o.perfumer.trim()
          ? o.perfumer.trim().slice(0, 120)
          : null,
      notes,
      accords,
    },
  };
}

// =============================================================================
// SUGGEST — candidate fragrances for a taste profile
// =============================================================================
// The model supplies the POOL. It does not rank, score, or explain — that is
// done locally in Dart against the note vectors, so every explanation shown to
// the user is arithmetic rather than prose.

export const suggestTool = {
  name: "propose_candidates",
  description:
    "Propose real, existing fragrances that fit the described taste profile. " +
    "Call exactly once.",
  strict: true,
  input_schema: {
    type: "object" as const,
    properties: {
      candidates: {
        type: "array",
        description: "Up to 15 real fragrances. Never invent one.",
        items: {
          type: "object",
          properties: {
            brand: { type: "string" },
            name: { type: "string" },
            concentration: { type: "string", enum: CONCENTRATIONS },
            why: {
              type: "string",
              description:
                "One sentence. Context for the app's own scoring, NOT shown to " +
                "the user as the reason — the app computes and words that " +
                "itself from the note vectors.",
            },
          },
          required: ["brand", "name", "concentration", "why"],
          additionalProperties: false,
        },
      },
    },
    required: ["candidates"],
    additionalProperties: false,
  },
};

export interface SuggestCandidate {
  brand: string;
  name: string;
  concentration: string;
  why: string;
}

export function validateSuggest(
  raw: unknown,
): { ok: true; value: SuggestCandidate[] } | { ok: false; reason: string } {
  if (typeof raw !== "object" || raw === null) {
    return { ok: false, reason: "not an object" };
  }
  const o = raw as Record<string, unknown>;
  if (!Array.isArray(o.candidates)) return { ok: false, reason: "candidates missing" };

  const out: SuggestCandidate[] = [];
  const seen = new Set<string>();
  for (const item of o.candidates.slice(0, 15)) {
    if (typeof item !== "object" || item === null) continue;
    const c = item as Record<string, unknown>;
    const brand = typeof c.brand === "string" ? c.brand.trim() : "";
    const name = typeof c.name === "string" ? c.name.trim() : "";
    if (!brand || !name) continue;
    if (brand.length > 120 || name.length > 200) continue;

    const concentration =
      typeof c.concentration === "string" &&
      (CONCENTRATIONS as readonly string[]).includes(c.concentration)
        ? c.concentration
        : "unknown";

    const dedupe = `${brand.toLowerCase()}|${name.toLowerCase()}|${concentration}`;
    if (seen.has(dedupe)) continue;
    seen.add(dedupe);

    out.push({
      brand,
      name,
      concentration,
      why: typeof c.why === "string" ? c.why.slice(0, 300) : "",
    });
  }
  return { ok: true, value: out };
}
