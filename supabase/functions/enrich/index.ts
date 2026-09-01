// POST /functions/v1/enrich
//
// One confirmed fragrance in, its note pyramid out.
//
// =============================================================================
// WHY THIS IS A SEPARATE CALL FROM `identify`
// =============================================================================
// `identify` returns up to three candidates and the user picks one. Generating
// pyramids for all three would pay three times for one answer, and two thirds
// of that spend is thrown away every scan.
//
// It also runs at most ONCE PER FRAGRANCE, ever, across all users: the caller
// checks the shared catalog first and only reaches here on a miss. The second
// person to scan a bottle of Sauvage costs nothing.
//
// =============================================================================
// THE HONESTY REQUIREMENT
// =============================================================================
// Note pyramids are exactly the kind of thing a model will confabulate
// fluently — plausible, specific, and wrong. A fragrance person spots an
// invented pyramid instantly, and every recommendation the app makes is
// computed from these notes, so a bad one is not a cosmetic error.
//
// Two defences: the schema's `known` flag gives the model an explicit, cheap
// way to decline (and the prompt makes declining the expected behaviour for
// anything obscure), and whatever comes back is stored with provenance `model`
// and rendered marked as unverified until a human confirms it.

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
import { enrichTool, validateEnrich } from "../_shared/schemas.ts";

const RATE_LIMIT = 60;

const SYSTEM_PROMPT = `You report the note pyramid of a named fragrance.

THE ONLY THING THAT MATTERS HERE IS NOT INVENTING ONE

Note pyramids are easy to fabricate convincingly. A plausible list of notes for a fragrance you do not actually know is indistinguishable, to a reader, from a real one — and this output is shown to users as fact and is used to compute every recommendation the app makes. A wrong pyramid does not degrade gracefully; it quietly corrupts everything downstream.

So: if you do not genuinely know this fragrance, set known to false and return empty arrays. That is a normal, expected, well-handled outcome — the app asks the user to fill it in. It is strictly better than a good guess.

Set known to false when:
  - You do not recognise the house at all.
  - You recognise the house but not this specific release.
  - You are thinking of a DIFFERENT concentration or flanker of the same name. Sauvage EDT, EDP, Parfum and Elixir have different pyramids; if you know one and were asked about another, you do not know this one.
  - You would be reconstructing the pyramid from what the fragrance is generally said to smell like rather than recalling the notes the house lists.

WHEN YOU DO KNOW IT
  - List only the notes the house itself publishes. Do not add notes reviewers commonly mention but the house does not list.
  - Put each note in the tier the house assigns it, in the order the house lists it, with position starting at 0.
  - A note the house lists in two tiers goes in both.
  - accords are the coarse families the fragrance reads as overall — "sweet", "woody", "fresh spicy", "amber". Weight them 0 to 1 by how strongly each reads.
  - family on a note is its own coarse family: bergamot is "citrus", sandalwood is "woody".

Call the report_pyramid tool exactly once.`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const user = await requireUser(req);
  if (!user) return json({ error: "unauthorized" }, 401);

  let body: { brand?: string; name?: string; concentration?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const brand = (body.brand ?? "").trim();
  const name = (body.name ?? "").trim();
  if (!brand || !name) return json({ error: "brand_and_name_required" }, 400);
  if (brand.length > 120 || name.length > 200) return json({ error: "too_long" }, 400);

  if (!(await withinRateLimit(user.id, "enrich", RATE_LIMIT))) {
    return json({ error: "rate_limited" }, 429);
  }

  const client = anthropicClient();
  if (!client) {
    console.error("ANTHROPIC_API_KEY is not configured");
    return json({ error: "not_configured" }, 503);
  }

  const concentration = (body.concentration ?? "unknown").trim();
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
      tools: [enrichTool],
      tool_choice: {
        type: "tool",
        name: "report_pyramid",
        disable_parallel_tool_use: true,
      },
      messages: [
        {
          role: "user",
          content:
            `Brand: ${brand}\nName: ${name}\nConcentration: ${concentration}\n\n` +
            `Report this fragrance's pyramid, or set known to false.`,
        },
      ],
    });

    const usable =
      message.stop_reason !== "refusal" && message.stop_reason !== "max_tokens";
    void recordUsage({
      userId: user.id,
      kind: "enrich",
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

    const validated = validateEnrich(extracted.input);
    if (!validated.ok) {
      console.error("enrich failed validation:", validated.reason);
      return json({ error: "schema_mismatch" }, 502);
    }

    return json({ ...validated.value, model: message.model });
  } catch (err) {
    return mapAnthropicError(err);
  }
});
