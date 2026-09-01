// POST /functions/v1/suggest
//
// A taste profile in, a POOL of real fragrances out.
//
// =============================================================================
// THIS ENDPOINT DOES NOT RECOMMEND ANYTHING
// =============================================================================
// It solves exactly one problem: cold start. With a thin catalog there is
// nothing to compute similarity against, so the model is asked what exists —
// which is the one part of this it is genuinely better at than a database.
//
// Ranking, scoring and every word of the explanation the user reads happen
// locally, in `lib/core/recommend.dart`, against IDF-weighted note vectors. The
// `why` field below is context for that scoring and is deliberately NEVER shown
// to the user.
//
// The reason for the split is checkability. A model asked to both pick and
// justify produces a fluent paragraph that cannot be verified against anything.
// A cosine over a note vocabulary produces a number, and the notes that drove
// it, and an explanation that is true by construction.

import {
  anthropicClient,
  CORS_HEADERS,
  DEFAULT_MODEL,
  extractToolInput,
  json,
  mapAnthropicError,
  recordUsage,
  requireUser,
  withinRateLimit,
} from "../_shared/anthropic.ts";
import { suggestTool, validateSuggest } from "../_shared/schemas.ts";

/** Lower than identify: this is a considered action, not a reflex. */
const RATE_LIMIT = 20;

const SYSTEM_PROMPT = `You propose real fragrances that a collector might buy next, given a description of what they already own.

YOUR ONLY JOB IS TO NAME REAL FRAGRANCES THAT EXIST

The app scores, ranks and explains these itself against its own note data. You are supplying the pool to choose from, not the recommendation. A candidate that does not exist wastes the slot completely and pollutes a shared catalog, so:

  - Never invent a fragrance, a flanker, or a concentration that was never released.
  - If you are unsure whether a specific flanker exists, propose the base release you are sure of instead.
  - Prefer fragrances that are actually purchasable now over discontinued ones.

WHAT MAKES A GOOD POOL
  - SPREAD, not fifteen variations on one theme. The app decides which are closest; give it range to choose from.
  - Include some obvious adjacencies AND some deliberate sideways steps. A pool of only safe picks makes the gap strategy useless.
  - Respect explicit gaps and patterns in the profile: if it says the shelf has no fresh or citrus fragrances, several candidates should be fresh or citrus.
  - When the profile says the collection is mostly clones, include the ORIGINALS those clones are of, by name.
  - Do not propose anything listed as already owned.
  - brand and name are separate; strip the house and the bottle size out of name. Keep Elixir, Intense, Absolu and Extreme in the name — they identify a different fragrance.

Call the propose_candidates tool exactly once.`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const user = await requireUser(req);
  if (!user) return json({ error: "unauthorized" }, 401);

  let body: { profile?: string; owned?: string[] };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const profile = (body.profile ?? "").trim();
  if (!profile) return json({ error: "profile_required" }, 400);
  if (profile.length > 4000) return json({ error: "profile_too_long" }, 413);

  const owned = Array.isArray(body.owned)
    ? body.owned.filter((s) => typeof s === "string").slice(0, 200)
    : [];

  if (!(await withinRateLimit(user.id, "suggest", RATE_LIMIT))) {
    return json({ error: "rate_limited" }, 429);
  }

  const client = anthropicClient();
  if (!client) {
    console.error("ANTHROPIC_API_KEY is not configured");
    return json({ error: "not_configured" }, 503);
  }

  const startedAt = Date.now();

  try {
    const message = await client.beta.messages.create({
      model: DEFAULT_MODEL,
      max_tokens: 8192,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system: [
        { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
      ],
      tools: [suggestTool],
      tool_choice: {
        type: "tool",
        name: "propose_candidates",
        disable_parallel_tool_use: true,
      },
      messages: [
        {
          role: "user",
          content:
            `TASTE PROFILE\n${profile}\n\n` +
            `ALREADY OWNED — do not propose any of these\n` +
            (owned.length ? owned.join("\n") : "(nothing yet)"),
        },
      ],
    });

    const usable =
      message.stop_reason !== "refusal" && message.stop_reason !== "max_tokens";
    void recordUsage({
      userId: user.id,
      kind: "suggest",
      model: message.model,
      inputTokens: message.usage?.input_tokens,
      outputTokens: message.usage?.output_tokens,
      cacheReadTokens: message.usage?.cache_read_input_tokens,
      cacheWriteTokens: message.usage?.cache_creation_input_tokens,
      durationMs: Date.now() - startedAt,
      ok: usable,
    });

    const extracted = extractToolInput(message);
    if (!extracted.ok) return extracted.response;

    const validated = validateSuggest(extracted.input);
    if (!validated.ok) {
      console.error("suggest failed validation:", validated.reason);
      return json({ error: "schema_mismatch" }, 502);
    }

    return json({ candidates: validated.value, model: message.model });
  } catch (err) {
    return mapAnthropicError(err);
  }
});
