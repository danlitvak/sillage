-- sillage — initial schema.
--
-- =============================================================================
-- THE ONE STRUCTURAL IDEA IN THIS FILE
-- =============================================================================
-- There are two kinds of data here and they have opposite sharing rules:
--
--   THE CATALOG  (brands, fragrances, notes, accords, clone edges)
--     Globally READABLE. One row per real fragrance, shared by everyone, so a
--     bottle is only ever identified once and a correction improves it for
--     every future scan. Never written directly by a client — every write goes
--     through a SECURITY DEFINER function that records who proposed it. That
--     gives vandalism, accidental duplicates and provenance a single chokepoint
--     instead of three separate problems.
--
--   YOUR COLLECTION  (collection_items, scans, llm_usage, feedback)
--     RLS'd to auth.uid() from this migration, not bolted on later. Nothing
--     here is visible to another account.
--
-- Getting that split wrong in the other direction — per-user catalog rows —
-- would mean the note vocabulary is per-user too, and the IDF weighting that
-- makes the recommender work has nothing to compute against.

-- =============================================================================
-- ENUMS
-- =============================================================================

-- Mirrors Concentration.wire in lib/core/identity.dart. The Dart enum's `wire`
-- values are deliberately decoupled from its Dart identifiers precisely so this
-- list and that one can be kept in step by hand without a rename breaking them.
create type concentration as enum (
  'extrait', 'edp', 'edt', 'edc', 'eau_fraiche', 'oil', 'unknown'
);

-- Where a fact came from. Precedence is user > brand > model, enforced in
-- catalog_propose_fragrance() rather than by convention.
create type provenance as enum ('model', 'brand', 'user');

-- Where a note sits in the pyramid. Drives the tier weighting in the
-- recommender: base notes are what you smell for six hours, top notes are gone
-- in fifteen minutes, so they cannot count equally.
create type note_tier as enum ('top', 'heart', 'base');

-- What kind of house this is.
--
-- `clone_house` is a hint for display, NOT the signal the clone detector uses —
-- that keys off an actual clone_of edge on the fragrance, because the Arabian
-- houses (Lattafa, Armaf, Afnan) release plenty of originals alongside their
-- dupes and tarring the whole house misreads a collection.
create type brand_tier as enum (
  'designer', 'niche', 'clone_house', 'arabian', 'indie', 'celebrity', 'unknown'
);

-- =============================================================================
-- CATALOG
-- =============================================================================

create table brands (
  id uuid primary key default gen_random_uuid(),
  -- The canonical key from canonicalBrandKey() — alias-resolved, separator
  -- free. Unique because two rows here means a split house, which hides the
  -- house-loyalty pattern the app exists to spot.
  key text not null unique,
  display_name text not null,
  tier brand_tier not null default 'unknown',
  tier_source provenance not null default 'model',
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);

create table fragrances (
  id uuid primary key default gen_random_uuid(),
  brand_id uuid not null references brands(id) on delete restrict,

  -- The full catalog key, exactly as FragranceKey.value builds it:
  --   brand|name|concentration
  -- Stored whole AND split, because the app looks up by the whole thing and the
  -- recommender groups by the parts.
  key text not null unique,
  name_key text not null,
  concentration concentration not null default 'unknown',

  -- Verbatim as the house writes it, diacritics and capitals intact. The key is
  -- for matching; this is for reading. Never derive one from the other at
  -- display time — that is how "L'Homme" becomes "lhomme" on screen.
  display_name text not null,

  release_year int check (release_year is null or release_year between 1700 and 2100),
  perfumer text,

  -- Provenance, per field group rather than per column: notes and accords move
  -- together when someone corrects a pyramid, and splitting their provenance
  -- would let a row claim its notes are user-verified when only the year was.
  identity_source provenance not null default 'model',
  notes_source provenance not null default 'model',

  -- Set when a human confirms the pyramid. Null means "model-proposed, shown
  -- marked as unverified" — the UI reads this, it is not decoration.
  notes_verified_at timestamptz,
  notes_verified_by uuid references auth.users(id) on delete set null,

  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create index fragrances_brand_idx on fragrances(brand_id);
create index fragrances_name_key_idx on fragrances(name_key);

-- The note vocabulary.
--
-- Canonical, with synonyms folded in, because "bergamot", "bergamot oil" and
-- "Calabrian bergamot" are one note and treating them as three makes every
-- similarity score noise.
create table notes (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  display_name text not null,
  -- Coarse family, for the accord gap analysis to have something to roll up to.
  family text,
  created_at timestamptz not null default now()
);

create table note_aliases (
  alias text primary key,
  note_id uuid not null references notes(id) on delete cascade
);

create table fragrance_notes (
  fragrance_id uuid not null references fragrances(id) on delete cascade,
  note_id uuid not null references notes(id) on delete cascade,
  tier note_tier not null,
  -- Where in its tier it was listed. Houses list the most prominent first, so
  -- position is real signal, not presentation order.
  position int not null default 0,
  primary key (fragrance_id, note_id, tier)
);

create index fragrance_notes_note_idx on fragrance_notes(note_id);

create table accords (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  display_name text not null
);

create table fragrance_accords (
  fragrance_id uuid not null references fragrances(id) on delete cascade,
  accord_id uuid not null references accords(id) on delete cascade,
  -- 0..1. How strongly this accord reads in the composition.
  weight real not null default 1.0 check (weight >= 0 and weight <= 1),
  primary key (fragrance_id, accord_id)
);

-- Clone edges: this fragrance is a dupe of that one.
--
-- Hand-curated seed plus user contributions. Deliberately NOT scraped: it is
-- small enough to verify by hand, and it is the single most distinctive signal
-- the recommender has.
create table clone_of (
  clone_id uuid not null references fragrances(id) on delete cascade,
  original_id uuid not null references fragrances(id) on delete cascade,
  confidence real not null default 0.8 check (confidence >= 0 and confidence <= 1),
  source provenance not null default 'model',
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  primary key (clone_id, original_id),
  -- A fragrance cannot be a clone of itself. Cheap to assert, and without it a
  -- single bad model response makes "here's the original" point at the bottle
  -- you are already looking at.
  constraint clone_is_not_its_own_original check (clone_id <> original_id)
);

create index clone_of_original_idx on clone_of(original_id);

-- =============================================================================
-- PER-USER
-- =============================================================================

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);

create type ownership_status as enum ('have', 'had', 'want');

create table collection_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fragrance_id uuid not null references fragrances(id) on delete restrict,

  status ownership_status not null default 'have',

  -- Your own photo of your own bottle, in the per-user storage bucket. Nicer
  -- than a stock image and it sidesteps image licensing entirely.
  photo_path text,

  bottle_ml int check (bottle_ml is null or bottle_ml > 0),
  acquired_on date,
  -- 0..10, your rating. Weights the collection centroid, so a bottle you love
  -- pulls recommendations harder than one you tolerate.
  rating real check (rating is null or (rating >= 0 and rating <= 10)),
  note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- One row per fragrance per user. Two bottles of the same juice is a
  -- quantity, not a second collection entry — and duplicates would double-count
  -- in every profile statistic.
  unique (user_id, fragrance_id)
);

create index collection_items_user_idx on collection_items(user_id);

-- Every identification attempt, kept whole.
--
-- `raw_response` is the model's output VERBATIM, before validation. When an
-- identification turns out wrong, this is the difference between "we can see
-- exactly what it said and why the parser accepted it" and a mystery. Same
-- reasoning as knockabase storing the raw transcript alongside the extraction.
create table scans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  photo_path text,
  -- What the model claimed it could read off the label. Shown to the user as
  -- the evidence behind a candidate.
  label_text text,
  raw_response jsonb,
  -- Which candidate the user actually confirmed, if any. Null means they
  -- rejected all of them — the most interesting rows in the table.
  chosen_fragrance_id uuid references fragrances(id) on delete set null,
  rejected boolean not null default false,
  created_at timestamptz not null default now()
);

create index scans_user_idx on scans(user_id, created_at desc);

-- Cost ledger. Ported from knockabase/supabase/migrations/0025_llm_usage.sql.
--
-- Written on EVERY call including refusals and truncations, because those cost
-- the same as a success and recording only the happy path understates the bill
-- exactly when something is going wrong repeatedly.
create table llm_usage (
  id bigserial primary key,
  user_id uuid references auth.users(id) on delete set null,
  kind text not null,
  -- The RESOLVED model id the API answered with, never the alias requested.
  -- Pricing a call against what you asked for is how a silent model change
  -- becomes a silent cost change.
  model text not null,
  input_tokens int,
  output_tokens int,
  cache_read_tokens int,
  cache_write_tokens int,
  duration_ms int,
  ok boolean not null default true,
  created_at timestamptz not null default now()
);

create index llm_usage_user_idx on llm_usage(user_id, created_at desc);

create type rec_verdict as enum ('shown', 'saved', 'dismissed', 'bought');

create table recommendation_feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fragrance_id uuid not null references fragrances(id) on delete cascade,
  -- Which strategy produced it, so a strategy that only ever gets dismissed is
  -- visible as such rather than averaged away.
  strategy text not null,
  verdict rec_verdict not null,
  created_at timestamptz not null default now(),
  unique (user_id, fragrance_id, strategy)
);

create index recommendation_feedback_user_idx on recommendation_feedback(user_id);

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================
-- Enabled on EVERY table. A table with RLS off is readable by any authenticated
-- client holding the anon key, which is shipped inside the app.

alter table brands              enable row level security;
alter table fragrances          enable row level security;
alter table notes               enable row level security;
alter table note_aliases        enable row level security;
alter table fragrance_notes     enable row level security;
alter table accords             enable row level security;
alter table fragrance_accords   enable row level security;
alter table clone_of            enable row level security;
alter table profiles            enable row level security;
alter table collection_items    enable row level security;
alter table scans               enable row level security;
alter table llm_usage           enable row level security;
alter table recommendation_feedback enable row level security;

-- Catalog: readable by any signed-in user, writable by none of them directly.
-- The absence of an INSERT/UPDATE policy is the enforcement — writes arrive
-- through the SECURITY DEFINER function below, which bypasses RLS by design.
create policy catalog_read_brands on brands for select to authenticated using (true);
create policy catalog_read_fragrances on fragrances for select to authenticated using (true);
create policy catalog_read_notes on notes for select to authenticated using (true);
create policy catalog_read_note_aliases on note_aliases for select to authenticated using (true);
create policy catalog_read_fragrance_notes on fragrance_notes for select to authenticated using (true);
create policy catalog_read_accords on accords for select to authenticated using (true);
create policy catalog_read_fragrance_accords on fragrance_accords for select to authenticated using (true);
create policy catalog_read_clone_of on clone_of for select to authenticated using (true);

-- Per-user: you see and touch your own rows and nobody else's.
create policy own_profile on profiles for all to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy own_collection on collection_items for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy own_scans on scans for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy own_feedback on recommendation_feedback for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- The ledger is read-only to its owner. Writes come from the Edge Function on
-- the service role, so a client cannot forge or erase its own cost record.
create policy own_llm_usage_read on llm_usage for select to authenticated
  using (user_id = (select auth.uid()));

-- =============================================================================
-- PROFILE BOOTSTRAP
-- =============================================================================

create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', null))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- =============================================================================
-- updated_at
-- =============================================================================

create function touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger fragrances_touch before update on fragrances
  for each row execute function touch_updated_at();

create trigger collection_items_touch before update on collection_items
  for each row execute function touch_updated_at();

-- =============================================================================
-- TABLE GRANTS
-- =============================================================================
-- RLS AND GRANTS ARE TWO DIFFERENT GATES AND BOTH ARE REQUIRED.
--
-- A policy answers "which ROWS may this role see". A grant answers "may this
-- role touch this table at all". Enabling RLS and writing policies without
-- granting gets you `permission denied for table fragrances` on every single
-- read — the policies are never even consulted.
--
-- This is easy to miss because Supabase configures default privileges for the
-- `postgres` role, so tables created in some contexts pick grants up for free.
-- Migrations do not always run in one of those contexts, and the failure only
-- surfaces the first time a real client reads a real table. Found exactly that
-- way, against a local stack, before any of it was deployed.
--
-- Granted deliberately narrowly:
--   * the catalog is SELECT-only for clients — writes go through
--     catalog_propose_fragrance (see 20260831120100_catalog_writes.sql)
--   * per-user tables get full DML, and RLS confines it to the caller's rows
--   * llm_usage is SELECT-only: the Edge Function writes it on the service
--     role, so a client cannot forge or erase its own cost record

grant select on
  brands, fragrances, notes, note_aliases, fragrance_notes,
  accords, fragrance_accords, clone_of
  to authenticated;

grant select, insert, update, delete on
  profiles, collection_items, scans, recommendation_feedback
  to authenticated;

grant select on llm_usage to authenticated;
