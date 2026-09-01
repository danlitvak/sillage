-- The single chokepoint through which the shared catalog is written.
--
-- =============================================================================
-- WHY A FUNCTION AND NOT AN INSERT POLICY
-- =============================================================================
-- The catalog is shared. If clients could INSERT into `fragrances` directly,
-- three things go wrong at once and only one of them is obvious:
--
--   1. VANDALISM is possible (obvious).
--   2. DUPLICATES arrive whenever two clients race on the same new fragrance,
--      because a client cannot check-then-insert atomically. The unique
--      constraint on `key` would reject the loser with an error the user reads
--      as "scanning is broken".
--   3. PROVENANCE BECOMES A CONVENTION rather than a rule. A client would be
--      trusted to say "these notes are user-verified", and nothing would stop a
--      later model pass from overwriting a correction a human made — which is
--      the exact promise the app makes about its data.
--
-- One SECURITY DEFINER function fixes all three: it upserts idempotently, it
-- stamps the caller, and it refuses to let lower-provenance data overwrite
-- higher-provenance data.

-- Precedence as a number, so it can be compared. user(3) > brand(2) > model(1).
create function provenance_rank(p provenance) returns int
language sql immutable as $$
  select case p when 'user' then 3 when 'brand' then 2 else 1 end;
$$;

-- Resolve or create a brand.
create function catalog_upsert_brand(
  p_key text,
  p_display_name text,
  p_tier brand_tier default 'unknown'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if p_key is null or length(trim(p_key)) = 0 then
    raise exception 'brand key is required';
  end if;

  insert into brands (key, display_name, tier, created_by)
  values (p_key, coalesce(nullif(trim(p_display_name), ''), p_key), p_tier, auth.uid())
  on conflict (key) do update
    -- Only fill a tier that is still unknown. A house someone has classified
    -- must not be reclassified by the next scan's guess.
    set tier = case
      when brands.tier = 'unknown' then excluded.tier
      else brands.tier
    end
  returning id into v_id;

  return v_id;
end;
$$;

-- Resolve or create a note by its canonical key.
create function catalog_upsert_note(
  p_key text,
  p_display_name text,
  p_family text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  -- An alias wins over creating a new row: this is what keeps "bergamot oil"
  -- from becoming a second note beside "bergamot" and halving both their IDF
  -- weights.
  select note_id into v_id from note_aliases where alias = p_key;
  if v_id is not null then
    return v_id;
  end if;

  insert into notes (key, display_name, family)
  values (p_key, coalesce(nullif(trim(p_display_name), ''), p_key), p_family)
  on conflict (key) do update
    set family = coalesce(notes.family, excluded.family)
  returning id into v_id;

  return v_id;
end;
$$;

-- Propose a fragrance, with its pyramid, at a stated provenance.
--
-- Idempotent on the catalog key: calling it twice with the same key updates one
-- row rather than creating two. That is what makes "the same bottle scanned by
-- two people" cost one row and one identification.
--
-- p_notes is a JSON array of {key, display_name, tier, position, family}.
create function catalog_propose_fragrance(
  p_brand_key text,
  p_brand_display text,
  p_brand_tier brand_tier,
  p_fragrance_key text,
  p_name_key text,
  p_display_name text,
  p_concentration concentration,
  p_release_year int,
  p_perfumer text,
  p_notes jsonb,
  p_accords jsonb,
  p_source provenance
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_brand_id uuid;
  v_fragrance_id uuid;
  v_existing_notes_rank int;
  v_incoming_rank int := provenance_rank(p_source);
  v_note jsonb;
  v_note_id uuid;
  v_accord jsonb;
  v_accord_id uuid;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  if p_fragrance_key is null or length(trim(p_fragrance_key)) = 0 then
    raise exception 'fragrance key is required';
  end if;

  v_brand_id := catalog_upsert_brand(p_brand_key, p_brand_display, p_brand_tier);

  insert into fragrances (
    brand_id, key, name_key, concentration, display_name,
    release_year, perfumer, identity_source, notes_source, created_by
  ) values (
    v_brand_id, p_fragrance_key, p_name_key, coalesce(p_concentration, 'unknown'),
    p_display_name, p_release_year, p_perfumer, p_source, p_source, auth.uid()
  )
  on conflict (key) do update
    -- Identity fields fill gaps but never overwrite a better source.
    set display_name = case
          when provenance_rank(excluded.identity_source) >= provenance_rank(fragrances.identity_source)
          then excluded.display_name else fragrances.display_name end,
        release_year = coalesce(fragrances.release_year, excluded.release_year),
        perfumer = coalesce(fragrances.perfumer, excluded.perfumer),
        identity_source = case
          when provenance_rank(excluded.identity_source) > provenance_rank(fragrances.identity_source)
          then excluded.identity_source else fragrances.identity_source end
  returning id, provenance_rank(notes_source) into v_fragrance_id, v_existing_notes_rank;

  -- ---------------------------------------------------------------------
  -- THE PYRAMID. This is the rule the whole provenance story rests on.
  --
  -- Notes are replaced ONLY when the incoming source is at least as good as
  -- what is already stored. A model pass (rank 1) therefore cannot overwrite a
  -- correction a human made (rank 3), no matter how many times the bottle is
  -- rescanned — which is the promise the UI makes when it stops marking a
  -- pyramid as unverified.
  -- ---------------------------------------------------------------------
  if p_notes is not null and jsonb_array_length(p_notes) > 0
     and v_incoming_rank >= v_existing_notes_rank then

    delete from fragrance_notes where fragrance_id = v_fragrance_id;

    for v_note in select * from jsonb_array_elements(p_notes) loop
      v_note_id := catalog_upsert_note(
        v_note->>'key',
        coalesce(v_note->>'display_name', v_note->>'key'),
        v_note->>'family'
      );
      insert into fragrance_notes (fragrance_id, note_id, tier, position)
      values (
        v_fragrance_id,
        v_note_id,
        coalesce((v_note->>'tier')::note_tier, 'heart'),
        coalesce((v_note->>'position')::int, 0)
      )
      on conflict (fragrance_id, note_id, tier) do nothing;
    end loop;

    if p_accords is not null then
      delete from fragrance_accords where fragrance_id = v_fragrance_id;
      for v_accord in select * from jsonb_array_elements(p_accords) loop
        insert into accords (key, display_name)
        values (v_accord->>'key', coalesce(v_accord->>'display_name', v_accord->>'key'))
        on conflict (key) do update set display_name = accords.display_name
        returning id into v_accord_id;

        insert into fragrance_accords (fragrance_id, accord_id, weight)
        values (v_fragrance_id, v_accord_id, coalesce((v_accord->>'weight')::real, 1.0))
        on conflict (fragrance_id, accord_id) do update set weight = excluded.weight;
      end loop;
    end if;

    update fragrances
      set notes_source = p_source,
          notes_verified_at = case when p_source = 'user' then now() else notes_verified_at end,
          notes_verified_by = case when p_source = 'user' then auth.uid() else notes_verified_by end
      where id = v_fragrance_id;
  end if;

  return v_fragrance_id;
end;
$$;

-- Clients call these; they do not touch the tables.
revoke all on function catalog_propose_fragrance from public;
revoke all on function catalog_upsert_brand from public;
revoke all on function catalog_upsert_note from public;
grant execute on function catalog_propose_fragrance to authenticated;

-- upsert_brand / upsert_note are internal helpers of the function above. Not
-- granted, so a client cannot create catalog rows that no fragrance references.
