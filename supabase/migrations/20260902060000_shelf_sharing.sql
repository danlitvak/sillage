-- Opt-in, revocable shelf sharing by secret link.
--
-- =============================================================================
-- WHY THIS IS ONE FUNCTION AND NOT A SET OF POLICIES
-- =============================================================================
-- This is the first feature that lets anyone read a row they do not own, so it
-- is the one place in the schema where a mistake leaks a stranger's data rather
-- than merely breaking a screen.
--
-- The obvious implementation adds `anon` to the catalog read policies and a
-- policy on `collection_items` that permits reading rows whose owner has
-- sharing on. That works, and it is the wrong shape:
--
--   * It widens FIVE tables to satisfy one feature, and every future column on
--     any of them is exposed by default rather than by decision.
--   * A policy keyed on "the owner is sharing" is enumerable: any caller can
--     ask for all shared rows and walk the whole set. The slug stops being a
--     secret and becomes a formality.
--   * The field set — what a shared shelf reveals — ends up spread across five
--     policies and a client query, where nobody can read it in one go.
--
-- So instead: ONE `security definer` function, keyed on the SLUG, returning
-- exactly the agreed fields. It cannot be enumerated (no slug, no row), the
-- exposed shape is legible in one place, and no table's RLS changes at all.
--
-- =============================================================================
-- WHAT A SHARED SHELF REVEALS, AND WHAT IT DELIBERATELY DOES NOT
-- =============================================================================
-- SHOWN:    display name, fragrances, houses, concentrations, note pyramids,
--           accords, dupe flags, provenance, and the owner's 0-10 ratings.
-- WITHHELD: the owner's private note on each bottle, their photographs, when
--           they acquired it, bottle sizes, and their email.
--
-- Ratings are in because a shelf without them is a list rather than a taste;
-- the diary-shaped fields are out because they are the ones written for an
-- audience of one.

-- Sharing is off until asked for. A null slug IS the off state.
alter table profiles
  add column share_slug text unique,
  add column shared_at timestamptz;

comment on column profiles.share_slug is
  'Unguessable public handle for this shelf. Null means not shared. Rotated on '
  'every enable, so revoking is permanent for links already sent.';

-- ---------------------------------------------------------------------------
-- Slug generation
-- ---------------------------------------------------------------------------
-- 12 characters from a 32-symbol alphabet is 60 bits — not guessable, and short
-- enough to sit in a text message without wrapping. Ambiguous glyphs (0/O, 1/l)
-- are excluded so a slug read aloud or retyped survives the trip.
create function generate_share_slug() returns text
language plpgsql volatile as $$
declare
  alphabet constant text := '23456789abcdefghjkmnpqrstuvwxyz';
  result text := '';
  i int;
begin
  for i in 1..12 loop
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Turning sharing on
-- ---------------------------------------------------------------------------
-- Always mints a NEW slug, including when sharing was already on. That is what
-- makes revocation real: turning sharing off and on again invalidates every
-- link already sent, rather than resurrecting the old one.
create function share_shelf() returns text
language plpgsql security definer set search_path = public as $$
declare
  v_slug text;
  v_attempts int := 0;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;

  -- Retry on the vanishingly unlikely collision rather than failing the user's
  -- tap. Bounded so a broken generator cannot spin forever.
  loop
    v_slug := generate_share_slug();
    exit when not exists (select 1 from profiles where share_slug = v_slug);
    v_attempts := v_attempts + 1;
    if v_attempts > 10 then
      raise exception 'could not allocate a share slug';
    end if;
  end loop;

  update profiles
     set share_slug = v_slug, shared_at = now()
   where id = auth.uid();

  return v_slug;
end;
$$;

create function unshare_shelf() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  update profiles set share_slug = null, shared_at = null where id = auth.uid();
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading a shared shelf
-- ---------------------------------------------------------------------------
-- The only path by which one account's collection reaches another, and the only
-- place the shared field set is written down.
--
-- Returns null for an unknown or revoked slug — deliberately the same answer
-- for both, so a caller cannot tell "never existed" from "turned off".
create function get_shared_shelf(p_slug text) returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_owner uuid;
  v_name text;
  v_result jsonb;
begin
  if p_slug is null or length(p_slug) < 8 then
    return null;
  end if;

  select id, display_name into v_owner, v_name
    from profiles where share_slug = p_slug;

  if v_owner is null then
    return null;
  end if;

  select jsonb_build_object(
    'display_name', v_name,
    'shared_at', (select shared_at from profiles where id = v_owner),
    'items', coalesce(jsonb_agg(item order by item->>'display_name'), '[]'::jsonb)
  )
  into v_result
  from (
    select jsonb_build_object(
             'id', ci.id,
             'status', ci.status,
             -- Included: a shelf without ratings is a list, not a taste.
             'rating', ci.rating,
             -- NOT included, on purpose: ci.note, ci.photo_path,
             -- ci.acquired_on, ci.bottle_ml. Those are written for an audience
             -- of one.
             'fragrance_id', f.id,
             'display_name', f.display_name,
             'concentration', f.concentration,
             'release_year', f.release_year,
             'notes_source', f.notes_source,
             'brand_key', b.key,
             'brand_name', b.display_name,
             'brand_tier', b.tier,
             'is_clone', exists (
               select 1 from clone_of co where co.clone_id = f.id
             ),
             'notes', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'key', n.key,
                        'display_name', n.display_name,
                        'tier', fn.tier,
                        'position', fn.position,
                        'family', n.family)
                      order by fn.position)
                 from fragrance_notes fn
                 join notes n on n.id = fn.note_id
                where fn.fragrance_id = f.id), '[]'::jsonb),
             'accords', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'key', a.key,
                        'display_name', a.display_name,
                        'weight', fa.weight))
                 from fragrance_accords fa
                 join accords a on a.id = fa.accord_id
                where fa.fragrance_id = f.id), '[]'::jsonb)
           ) as item
      from collection_items ci
      join fragrances f on f.id = ci.fragrance_id
      join brands b on b.id = f.brand_id
     where ci.user_id = v_owner
  ) rows;

  return v_result;
end;
$$;

-- `anon` deliberately included: the whole point is a link a friend can tap
-- without making an account. They can call it only with a slug they were given.
revoke all on function get_shared_shelf(text) from public;
revoke all on function share_shelf from public;
revoke all on function unshare_shelf from public;
revoke all on function generate_share_slug from public;

grant execute on function get_shared_shelf(text) to anon, authenticated;
grant execute on function share_shelf to authenticated;
grant execute on function unshare_shelf to authenticated;

-- generate_share_slug stays ungranted: it is an implementation detail of
-- share_shelf, and handing it out would let a caller burn through slugs.
