// Shared Anthropic plumbing for every Edge Function.
//
// =============================================================================
// WHY THE MODEL CALL LIVES HERE AND NOT IN THE APP
// =============================================================================
// An API key shipped inside a Flutter APK is extractable in about thirty
// seconds — `strings` on the bundle finds it. Every model call therefore goes
// through an Edge Function, which is the only thing that ever sees
// ANTHROPIC_API_KEY, and which runs with `verify_jwt` so an anonymous caller
// cannot spend tokens at all.
//
// The error mapping below is ported from knockabase's /api/extract, which
// learned each of these branches the hard way. Read that file before changing
// anything here.

import Anthropic from "npm:@anthropic-ai/sdk@0.115.0";
import { createClient } from "jsr:@supabase/supabase-js@2";

/** Default model. Overridable per function, so a cheaper tier can be measured. */
export const DEFAULT_MODEL = Deno.env.get("SILLAGE_MODEL") ?? "claude-opus-5";

export const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

/**
 * Constructed per request, not at module scope: the SDK throws on a missing key
 * at construction time, and a module-scope client would make every function in
 * the project fail to boot on a deploy where the secret is not yet set.
 */
export function anthropicClient(): Anthropic | null {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return null;
  return new Anthropic({ apiKey });
}

/** Supabase client acting as the calling USER — so RLS applies to their rows. */
export function userClient(req: Request) {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    },
  );
}

/** Service-role client. Only for writes a user must not be able to forge. */
export function serviceClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}

export interface Caller {
  id: string;
}

/**
 * Resolves the caller, or null.
 *
 * `verify_jwt` already rejects an absent token at the platform edge, so this is
 * belt and braces — but it also gives us the user id, which every ledger row
 * and every rate-limit check needs.
 */
export async function requireUser(req: Request): Promise<Caller | null> {
  const supabase = userClient(req);
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) return null;
  return { id: data.user.id };
}

/**
 * Per-user rate limit, counted out of the cost ledger itself.
 *
 * No separate counter table: the ledger already records one row per call, so
 * counting it is both cheaper and impossible to disagree with the bill. One
 * user cannot burn the whole budget — which on a personal project with a real
 * card attached is not a theoretical concern.
 */
export async function withinRateLimit(
  userId: string,
  kind: string,
  maxPerHour: number,
): Promise<boolean> {
  const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count, error } = await serviceClient()
    .from("llm_usage")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .eq("kind", kind)
    .gte("created_at", since);

  // Fail OPEN on a counting error rather than locking the user out of their own
  // app because a SELECT hiccuped. The budget alarm is the real backstop.
  if (error) {
    console.error("rate limit check failed, allowing:", error.message);
    return true;
  }
  return (count ?? 0) < maxPerHour;
}

export interface UsageRecord {
  userId: string;
  kind: string;
  model: string;
  inputTokens?: number | null;
  outputTokens?: number | null;
  cacheReadTokens?: number | null;
  cacheWriteTokens?: number | null;
  durationMs: number;
  ok: boolean;
}

/**
 * Files a usage row.
 *
 * Called before any of the response branches, because a refusal and a
 * truncation cost exactly what a success costs. Recording only the happy path
 * understates the bill precisely when something is going wrong repeatedly.
 *
 * Not awaited by callers: nobody is waiting on this insert, and the user is
 * waiting on the response.
 */
export async function recordUsage(u: UsageRecord): Promise<void> {
  const { error } = await serviceClient().from("llm_usage").insert({
    user_id: u.userId,
    kind: u.kind,
    model: u.model,
    input_tokens: u.inputTokens ?? null,
    output_tokens: u.outputTokens ?? null,
    cache_read_tokens: u.cacheReadTokens ?? null,
    cache_write_tokens: u.cacheWriteTokens ?? null,
    duration_ms: u.durationMs,
    ok: u.ok,
  });
  if (error) console.error("usage ledger insert failed:", error.message);
}

/**
 * Maps an SDK exception to a response the app can act on.
 *
 * Each branch exists because the app does something different: an expired key
 * means "tell the user to add it by hand and keep their photo", a rate limit
 * means "back off and retry", a connection error means "retry from the outbox".
 * Collapsing them into one 500 makes all three look like "the app is broken".
 */
export function mapAnthropicError(err: unknown): Response {
  if (
    err instanceof Anthropic.AuthenticationError ||
    err instanceof Anthropic.PermissionDeniedError
  ) {
    // Anthropic keys are created with a chosen expiry. When one lapses every
    // call 401s at once and, from a phone, looks identical to "the app broke".
    // Naming it here turns an afternoon of debugging into a two-minute
    // rotation. knockabase lost an afternoon to exactly this.
    console.error(
      "ANTHROPIC_KEY_EXPIRED_OR_INVALID — rotate at console.anthropic.com and " +
        "update the ANTHROPIC_API_KEY secret with `supabase secrets set`.",
    );
    return json(
      {
        error: "key_invalid",
        detail: "AI credentials are expired or invalid. Add the bottle by hand for now.",
      },
      503,
    );
  }
  if (err instanceof Anthropic.RateLimitError) {
    return json({ error: "rate_limited" }, 429);
  }
  if (err instanceof Anthropic.APIConnectionError) {
    return json({ error: "upstream_unreachable" }, 503);
  }
  if (err instanceof Anthropic.APIError) {
    console.error("anthropic error", err.status, err.message);
    return json({ error: "upstream_failed" }, 502);
  }
  console.error("unexpected error", err);
  return json({ error: "failed" }, 500);
}

/**
 * Pulls the single forced tool call out of a response, or returns a Response
 * describing why there isn't one.
 *
 * Opus 5 runs safety classifiers and can decline with a 200 and empty content,
 * so reading content[0] unconditionally would throw. Both non-content stop
 * reasons are checked before anything indexes into the array.
 */
export function extractToolInput(
  // deno-lint-ignore no-explicit-any
  message: any,
): { ok: true; input: unknown } | { ok: false; response: Response } {
  if (message.stop_reason === "refusal") {
    return {
      ok: false,
      response: json(
        { error: "refused", detail: "The model declined to process this image." },
        422,
      ),
    };
  }
  if (message.stop_reason === "max_tokens") {
    return {
      ok: false,
      response: json(
        { error: "truncated", detail: "Response was cut off. Try again." },
        422,
      ),
    };
  }
  // deno-lint-ignore no-explicit-any
  const toolUse = message.content?.find((b: any) => b.type === "tool_use");
  if (!toolUse) {
    return { ok: false, response: json({ error: "no_tool_call" }, 502) };
  }
  return { ok: true, input: toolUse.input };
}

export { Anthropic };
