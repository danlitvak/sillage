// POST /functions/v1/identify
//
// A photograph of a bottle in, ranked candidates out. Writes nothing to the
// catalog — the user confirms a candidate first, and only then does the app
// call `enrich` and the catalog write function.
//
// =============================================================================
// THE PROMPT IS THE HARD PART OF THIS FILE
// =============================================================================
// Bottle photos are ambiguous by construction: houses reuse one bottle across a
// whole line, so Sauvage EDT, EDP, Parfum and Elixir are the same glass with a
// different cap and one different word on the label. The prompt's job is to
// stop the model doing the natural thing — recognising the SHAPE and reporting
// the most famous release that uses it.
//
// Hence: read the label, report what you read, refuse when you cannot, and
// return several candidates rather than one confident answer.

import {
  Anthropic,
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
import { identifyTool, validateIdentify } from "../_shared/schemas.ts";

/** Scans per user per hour. Generous for real use, a hard stop on a runaway loop. */
const RATE_LIMIT = 60;

/** ~7MB of base64 is ~5MB of image, comfortably past what the client sends. */
const MAX_IMAGE_CHARS = 7_000_000;

const ALLOWED_MEDIA = ["image/jpeg", "image/png", "image/webp"];

/**
 * The cacheable half of the system prompt.
 *
 * Anthropic's prompt cache is an EXACT PREFIX MATCH, so this block must not
 * depend on the request in any way. Anything per-request goes in the second
 * block, after the breakpoint. Getting that backwards writes a fresh cache
 * entry on every scan and reads none of them back — all of the write premium,
 * none of the discount.
 *
 * On Opus 5 the minimum cacheable prefix is 512 tokens and this block is well
 * past it, so unlike knockabase's Haiku default the marker here actually pays.
 */
const SYSTEM_PROMPT = `You identify fragrances from photographs of their bottles.

WHAT MAKES THIS HARD
A fragrance house reuses one bottle design across its entire line. Dior Sauvage EDT, EDP, Parfum and Elixir are the same glass with a different cap colour and one different word on the label. Versace Eros, Eros Flame and Eros Parfum share a bottle. Flankers are the norm, not the exception.

So the shape of the bottle tells you the LINE at best, and frequently not even that. The text on the label is what tells you the product.

RULES
1. READ, do not recognise. Report the text you can actually see in label_text, verbatim, including words you cannot interpret. If the photo is blurry, angled, or the label faces away, say so by setting legible to false and returning fewer candidates — or none.

2. NEVER GUESS THE CONCENTRATION. Eau de Toilette, Eau de Parfum, Parfum and Elixir have different note pyramids and are different products. If the strength is not printed legibly in the photograph, return "unknown". Returning "unknown" is correct and expected; the app asks the user. Inferring it from the bottle, or from which release happens to be most popular, produces a confident wrong answer that gets written into a shared catalog.

3. MARKETING WORDS ARE PART OF THE NAME. Elixir, Intense, Absolu, Extreme, Profumo and Le Parfum identify a DIFFERENT fragrance, not a strength of the same one. Keep them in the name field. Do not move them to concentration.

4. STRIP THE HOUSE AND THE SIZE FROM THE NAME. brand is "Dior", name is "Sauvage Elixir". Not "Dior Sauvage Elixir", and never "Sauvage Elixir 100ml".

5. RETURN UP TO THREE CANDIDATES, most likely first. When a bottle is shared across a line and the label does not settle which one it is, that ambiguity IS the answer — return the plausible members of the line with honest confidences rather than picking one. The user confirms; a shortlist they can choose from is far more useful than a single wrong answer they have to notice.

6. AN EMPTY CANDIDATE LIST IS A VALID ANSWER. If you cannot tell, return no candidates. The app lets the user type the name. That is a much better outcome than a plausible invention, which lands in a catalog shared by every other user.

7. Confidence is about THIS PHOTOGRAPH. A fragrance you know well, photographed too blurrily to read, gets a low confidence.

Call the report_candidates tool exactly once.`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const user = await requireUser(req);
  if (!user) return json({ error: "unauthorized" }, 401);

  let body: { image?: string; mediaType?: string; hint?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const image = body.image;
  if (!image || typeof image !== "string") {
    return json({ error: "image_required" }, 400);
  }
  if (image.length > MAX_IMAGE_CHARS) {
    return json({ error: "image_too_large" }, 413);
  }

  const mediaType = body.mediaType ?? "image/jpeg";
  if (!ALLOWED_MEDIA.includes(mediaType)) {
    return json({ error: "unsupported_media_type" }, 415);
  }

  if (!(await withinRateLimit(user.id, "identify", RATE_LIMIT))) {
    return json(
      { error: "rate_limited", detail: `More than ${RATE_LIMIT} scans in an hour.` },
      429,
    );
  }

  const client = anthropicClient();
  if (!client) {
    console.error("ANTHROPIC_API_KEY is not configured");
    return json({ error: "not_configured" }, 503);
  }

  // Wall clock around the vendor call ONLY. The handler also authenticates and
  // writes a ledger row; what the user actually waits on is this.
  const startedAt = Date.now();

  try {
    const message = await client.beta.messages.create({
      model: DEFAULT_MODEL,
      max_tokens: 8192,
      // Opus 5 runs thinking by default and it counts against this cap. 8192
      // is generous for a response this small, sized so the JSON cannot be the
      // thing that gets truncated.

      // Server-side fallback: on a policy decline the API re-runs the same
      // request on a fallback model within the same call, rather than the user
      // seeing a scan simply fail. "default" routes by refusal category, so
      // there is no model list here to go stale.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",

      system: [
        { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
        // The per-request half, AFTER the breakpoint. Empty most of the time.
        {
          type: "text",
          text: body.hint
            ? `The user says this about the bottle: ${String(body.hint).slice(0, 200)}`
            : "The user gave no extra context.",
        },
      ],
      tools: [identifyTool],
      // Forced: the model must not answer in prose, and must not call twice.
      tool_choice: {
        type: "tool",
        name: "report_candidates",
        disable_parallel_tool_use: true,
      },
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              source: { type: "base64", media_type: mediaType, data: image },
            },
            {
              type: "text",
              text: "Identify this fragrance. Read the label before you decide.",
            },
          ],
        },
      ],
    });

    // Filed before any branch below: a refusal and a truncation cost what a
    // success costs. `message.model` is the RESOLVED id, not the alias asked
    // for — pricing against the alias is how a silent model change becomes a
    // silent cost change, and with fallbacks on, the resolved model genuinely
    // can differ from what was requested.
    const usable =
      message.stop_reason !== "refusal" && message.stop_reason !== "max_tokens";
    void recordUsage({
      userId: user.id,
      kind: "identify",
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

    const validated = validateIdentify(extracted.input);
    if (!validated.ok) {
      console.error("identify failed validation:", validated.reason);
      return json({ error: "schema_mismatch" }, 502);
    }

    return json({
      ...validated.value,
      // Returned so the client can store it verbatim on the scan row. When an
      // identification turns out wrong, the raw response is the difference
      // between seeing exactly what was said and a mystery.
      raw: extracted.input,
      model: message.model,
      usage: {
        input: message.usage?.input_tokens ?? 0,
        output: message.usage?.output_tokens ?? 0,
      },
    });
  } catch (err) {
    return mapAnthropicError(err);
  }
});

export { Anthropic };
