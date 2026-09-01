-- Local development seed.
--
-- =============================================================================
-- READ THIS BEFORE TRUSTING ANYTHING IN THIS FILE
-- =============================================================================
-- The fragrance NAMES and HOUSES here are real products. The NOTE PYRAMIDS,
-- ACCORD WEIGHTS and CLONE EDGES are illustrative fixture data written to give
-- the taste profile and the recommender something to compute against on a fresh
-- local database. They are NOT verified against what the houses publish.
--
-- Every row is therefore inserted at `model` provenance, which means the app
-- renders all of it marked UNVERIFIED — exactly as it would treat anything a
-- model proposed at runtime. That is the point: the seed is subject to the same
-- honesty rule as production data, so a screenshot taken against it cannot
-- accidentally present unverified notes as fact.
--
-- Do not push this to a hosted project. `supabase db reset` applies it locally.
--
-- =============================================================================
-- WHY IT GOES THROUGH catalog_propose_fragrance
-- =============================================================================
-- Direct INSERTs would be shorter, and would exercise none of the logic the
-- catalog actually depends on. Routing the seed through the real function means
-- a fresh `db reset` re-proves the idempotent upsert, the brand alias
-- resolution and the provenance ranking every single time.

-- The function reads auth.uid(), so the seed needs a real user to act as.
--
-- THE EMPTY STRINGS BELOW ARE LOAD-BEARING. GoTrue scans the token columns
-- into non-nullable Go strings, so a NULL in any of them makes every auth
-- request fail with `500 Database error querying schema` — an error that names
-- neither the table nor the column and looks like the whole auth service is
-- broken. Postgres defaults them to NULL, so they have to be set by hand.
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change_token_new,
  email_change, email_change_token_current, phone_change,
  phone_change_token, reauthentication_token
)
values (
  '00000000-0000-4000-8000-000000000001'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated',
  'dev@sillage.local',
  -- bcrypt of 'sillage123'. A local-only fixture credential; the hosted
  -- project never sees this file.
  crypt('sillage123', gen_salt('bf')),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  '', '', '', '', '', '', '', ''
)
on conflict (id) do nothing;

-- Supabase needs a matching identity row for password sign-in to resolve.
insert into auth.identities (
  id, user_id, provider_id, identity_data, provider, last_sign_in_at,
  created_at, updated_at
)
values (
  gen_random_uuid(),
  '00000000-0000-4000-8000-000000000001'::uuid,
  '00000000-0000-4000-8000-000000000001',
  '{"sub":"00000000-0000-4000-8000-000000000001","email":"dev@sillage.local","email_verified":true}'::jsonb,
  'email', now(), now(), now()
)
on conflict do nothing;

begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------------
-- Composition chosen so the detectors have something real to find: a
-- clone-heavy shelf, one house appearing repeatedly, a note running through
-- most of it, and an accord that is well represented in the catalog and absent
-- from the collection.

-- Designers
select catalog_propose_fragrance('dior','Dior','designer',
  'dior|sauvage|edp','sauvage','Sauvage','edp'::concentration,2018,'Francois Demachy',
  '[{"key":"bergamot","display_name":"Bergamot","tier":"top","position":0,"family":"citrus"},
    {"key":"sichuan-pepper","display_name":"Sichuan Pepper","tier":"top","position":1,"family":"spicy"},
    {"key":"lavender","display_name":"Lavender","tier":"heart","position":0,"family":"aromatic"},
    {"key":"ambroxan","display_name":"Ambroxan","tier":"base","position":0,"family":"amber"},
    {"key":"vanilla","display_name":"Vanilla","tier":"base","position":1,"family":"sweet"}]'::jsonb,
  '[{"key":"fresh-spicy","display_name":"Fresh Spicy","weight":0.9},
    {"key":"amber","display_name":"Amber","weight":0.7}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('chanel','Chanel','designer',
  'chanel|bleudechanel|edp','bleudechanel','Bleu de Chanel','edp'::concentration,2014,'Jacques Polge',
  '[{"key":"grapefruit","display_name":"Grapefruit","tier":"top","position":0,"family":"citrus"},
    {"key":"mint","display_name":"Mint","tier":"top","position":1,"family":"aromatic"},
    {"key":"ginger","display_name":"Ginger","tier":"heart","position":0,"family":"spicy"},
    {"key":"cedar","display_name":"Cedar","tier":"base","position":0,"family":"woody"},
    {"key":"sandalwood","display_name":"Sandalwood","tier":"base","position":1,"family":"woody"}]'::jsonb,
  '[{"key":"woody","display_name":"Woody","weight":0.9},
    {"key":"citrus","display_name":"Citrus","weight":0.6}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('yvessaintlaurent','Yves Saint Laurent','designer',
  'yvessaintlaurent|y|edp','y','Y','edp'::concentration,2018,'Dominique Ropion',
  '[{"key":"apple","display_name":"Apple","tier":"top","position":0,"family":"fruity"},
    {"key":"ginger","display_name":"Ginger","tier":"top","position":1,"family":"spicy"},
    {"key":"sage","display_name":"Sage","tier":"heart","position":0,"family":"aromatic"},
    {"key":"amberwood","display_name":"Amberwood","tier":"base","position":0,"family":"amber"},
    {"key":"tonka-bean","display_name":"Tonka Bean","tier":"base","position":1,"family":"sweet"}]'::jsonb,
  '[{"key":"aromatic","display_name":"Aromatic","weight":0.8},
    {"key":"amber","display_name":"Amber","weight":0.6}]'::jsonb,'model'::provenance);

-- Niche
select catalog_propose_fragrance('creed','Creed','niche',
  'creed|aventus|edp','aventus','Aventus','edp'::concentration,2010,'Erwin Creed',
  '[{"key":"pineapple","display_name":"Pineapple","tier":"top","position":0,"family":"fruity"},
    {"key":"bergamot","display_name":"Bergamot","tier":"top","position":1,"family":"citrus"},
    {"key":"birch","display_name":"Birch","tier":"heart","position":0,"family":"woody"},
    {"key":"oakmoss","display_name":"Oakmoss","tier":"base","position":0,"family":"mossy"},
    {"key":"musk","display_name":"Musk","tier":"base","position":1,"family":"musky"}]'::jsonb,
  '[{"key":"fruity","display_name":"Fruity","weight":0.9},
    {"key":"smoky","display_name":"Smoky","weight":0.6}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('parfumsdemarly','Parfums de Marly','niche',
  'parfumsdemarly|layton|edp','layton','Layton','edp'::concentration,2016,'Hamid Merati-Kashani',
  '[{"key":"apple","display_name":"Apple","tier":"top","position":0,"family":"fruity"},
    {"key":"lavender","display_name":"Lavender","tier":"top","position":1,"family":"aromatic"},
    {"key":"violet","display_name":"Violet","tier":"heart","position":0,"family":"floral"},
    {"key":"vanilla","display_name":"Vanilla","tier":"base","position":0,"family":"sweet"},
    {"key":"sandalwood","display_name":"Sandalwood","tier":"base","position":1,"family":"woody"}]'::jsonb,
  '[{"key":"sweet","display_name":"Sweet","weight":0.9},
    {"key":"woody","display_name":"Woody","weight":0.6}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('kilian','Kilian','niche',
  'kilian|angelsshare|edp','angelsshare','Angels'' Share','edp'::concentration,2020,'Sidonie Lancesseur',
  '[{"key":"cognac","display_name":"Cognac","tier":"top","position":0,"family":"boozy"},
    {"key":"cinnamon","display_name":"Cinnamon","tier":"heart","position":0,"family":"spicy"},
    {"key":"tonka-bean","display_name":"Tonka Bean","tier":"base","position":0,"family":"sweet"},
    {"key":"vanilla","display_name":"Vanilla","tier":"base","position":1,"family":"sweet"},
    {"key":"oak","display_name":"Oak","tier":"base","position":2,"family":"woody"}]'::jsonb,
  '[{"key":"sweet","display_name":"Sweet","weight":0.9},
    {"key":"boozy","display_name":"Boozy","weight":0.8}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('maisonfranciskurkdjian','Maison Francis Kurkdjian','niche',
  'maisonfranciskurkdjian|baccaratrouge540|extrait','baccaratrouge540','Baccarat Rouge 540','extrait'::concentration,2017,'Francis Kurkdjian',
  '[{"key":"saffron","display_name":"Saffron","tier":"top","position":0,"family":"spicy"},
    {"key":"jasmine","display_name":"Jasmine","tier":"heart","position":0,"family":"floral"},
    {"key":"amberwood","display_name":"Amberwood","tier":"base","position":0,"family":"amber"},
    {"key":"cedar","display_name":"Cedar","tier":"base","position":1,"family":"woody"}]'::jsonb,
  '[{"key":"sweet","display_name":"Sweet","weight":0.8},
    {"key":"amber","display_name":"Amber","weight":0.9}]'::jsonb,'model'::provenance);

-- Clone / Arabian houses
select catalog_propose_fragrance('armaf','Armaf','clone_house',
  'armaf|clubdenuitintenseman|edt','clubdenuitintenseman','Club de Nuit Intense Man','edt'::concentration,2015,null,
  '[{"key":"pineapple","display_name":"Pineapple","tier":"top","position":0,"family":"fruity"},
    {"key":"lemon","display_name":"Lemon","tier":"top","position":1,"family":"citrus"},
    {"key":"birch","display_name":"Birch","tier":"heart","position":0,"family":"woody"},
    {"key":"vanilla","display_name":"Vanilla","tier":"base","position":0,"family":"sweet"},
    {"key":"musk","display_name":"Musk","tier":"base","position":1,"family":"musky"}]'::jsonb,
  '[{"key":"fruity","display_name":"Fruity","weight":0.9},
    {"key":"smoky","display_name":"Smoky","weight":0.5}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('lattafa','Lattafa','arabian',
  'lattafa|khamrah|edp','khamrah','Khamrah','edp'::concentration,2022,null,
  '[{"key":"cinnamon","display_name":"Cinnamon","tier":"top","position":0,"family":"spicy"},
    {"key":"nutmeg","display_name":"Nutmeg","tier":"top","position":1,"family":"spicy"},
    {"key":"dates","display_name":"Dates","tier":"heart","position":0,"family":"sweet"},
    {"key":"vanilla","display_name":"Vanilla","tier":"base","position":0,"family":"sweet"},
    {"key":"tonka-bean","display_name":"Tonka Bean","tier":"base","position":1,"family":"sweet"}]'::jsonb,
  '[{"key":"sweet","display_name":"Sweet","weight":0.95},
    {"key":"spicy","display_name":"Spicy","weight":0.7}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('lattafa','Lattafa','arabian',
  'lattafa|asad|edp','asad','Asad','edp'::concentration,2022,null,
  '[{"key":"pineapple","display_name":"Pineapple","tier":"top","position":0,"family":"fruity"},
    {"key":"black-pepper","display_name":"Black Pepper","tier":"top","position":1,"family":"spicy"},
    {"key":"tobacco","display_name":"Tobacco","tier":"heart","position":0,"family":"tobacco"},
    {"key":"vanilla","display_name":"Vanilla","tier":"base","position":0,"family":"sweet"},
    {"key":"cedar","display_name":"Cedar","tier":"base","position":1,"family":"woody"}]'::jsonb,
  '[{"key":"sweet","display_name":"Sweet","weight":0.8},
    {"key":"tobacco","display_name":"Tobacco","weight":0.7}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('lattafa','Lattafa','arabian',
  'lattafa|fakhar|edp','fakhar','Fakhar','edp'::concentration,2021,null,
  '[{"key":"apple","display_name":"Apple","tier":"top","position":0,"family":"fruity"},
    {"key":"lavender","display_name":"Lavender","tier":"heart","position":0,"family":"aromatic"},
    {"key":"vanilla","display_name":"Vanilla","tier":"base","position":0,"family":"sweet"},
    {"key":"amberwood","display_name":"Amberwood","tier":"base","position":1,"family":"amber"}]'::jsonb,
  '[{"key":"sweet","display_name":"Sweet","weight":0.9},
    {"key":"aromatic","display_name":"Aromatic","weight":0.6}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('afnan','Afnan','arabian',
  'afnan|9pm|edp','9pm','9PM','edp'::concentration,2020,null,
  '[{"key":"apple","display_name":"Apple","tier":"top","position":0,"family":"fruity"},
    {"key":"cinnamon","display_name":"Cinnamon","tier":"top","position":1,"family":"spicy"},
    {"key":"lavender","display_name":"Lavender","tier":"heart","position":0,"family":"aromatic"},
    {"key":"vanilla","display_name":"Vanilla","tier":"base","position":0,"family":"sweet"},
    {"key":"tonka-bean","display_name":"Tonka Bean","tier":"base","position":1,"family":"sweet"}]'::jsonb,
  '[{"key":"sweet","display_name":"Sweet","weight":0.9},
    {"key":"amber","display_name":"Amber","weight":0.6}]'::jsonb,'model'::provenance);

-- Two fresh/aquatic fragrances, present in the catalog and DELIBERATELY absent
-- from the seeded collection, so the accord-gap detector has something real to
-- find and the gap strategy has somewhere to point.
select catalog_propose_fragrance('acquadiparma','Acqua di Parma','niche',
  'acquadiparma|coloniaessenza|edc','coloniaessenza','Colonia Essenza','edc'::concentration,2010,null,
  '[{"key":"lemon","display_name":"Lemon","tier":"top","position":0,"family":"citrus"},
    {"key":"bergamot","display_name":"Bergamot","tier":"top","position":1,"family":"citrus"},
    {"key":"petitgrain","display_name":"Petitgrain","tier":"heart","position":0,"family":"green"},
    {"key":"vetiver","display_name":"Vetiver","tier":"base","position":0,"family":"woody"}]'::jsonb,
  '[{"key":"citrus","display_name":"Citrus","weight":0.95},
    {"key":"fresh","display_name":"Fresh","weight":0.9}]'::jsonb,'model'::provenance);

select catalog_propose_fragrance('issey miyake','Issey Miyake','designer',
  'isseymiyake|lieaudissey|edt','lieaudissey','L''Eau d''Issey','edt'::concentration,1994,'Jacques Cavallier',
  '[{"key":"yuzu","display_name":"Yuzu","tier":"top","position":0,"family":"citrus"},
    {"key":"lotus","display_name":"Lotus","tier":"heart","position":0,"family":"aquatic"},
    {"key":"cedar","display_name":"Cedar","tier":"base","position":0,"family":"woody"},
    {"key":"musk","display_name":"Musk","tier":"base","position":1,"family":"musky"}]'::jsonb,
  '[{"key":"fresh","display_name":"Fresh","weight":0.9},
    {"key":"aquatic","display_name":"Aquatic","weight":0.85}]'::jsonb,'model'::provenance);

commit;

-- ---------------------------------------------------------------------------
-- Clone edges
-- ---------------------------------------------------------------------------
-- Widely-cited pairs only, at a confidence below 1 and at `model` provenance,
-- because "is X a dupe of Y" is a community judgement rather than a fact a
-- house publishes.
insert into clone_of (clone_id, original_id, confidence, source)
select c.id, o.id, 0.9, 'model'::provenance
from fragrances c, fragrances o
where c.key = 'armaf|clubdenuitintenseman|edt' and o.key = 'creed|aventus|edp'
on conflict do nothing;

insert into clone_of (clone_id, original_id, confidence, source)
select c.id, o.id, 0.8, 'model'::provenance
from fragrances c, fragrances o
where c.key = 'lattafa|khamrah|edp' and o.key = 'kilian|angelsshare|edp'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- A starting shelf for the dev user
-- ---------------------------------------------------------------------------
-- Seven bottles, chosen so every detector has a real answer:
--   * 2 of 7 carry a clone edge      -> clone-buyer does NOT fire (needs > 50%)
--   * 3 of 7 are Lattafa             -> house loyalty DOES fire
--   * vanilla is in 6 of 7           -> note obsession DOES fire
--   * nothing fresh, aquatic, citrus -> accord gap DOES fire, and the gap
--                                       strategy has two catalog rows to offer
insert into collection_items (user_id, fragrance_id, status, rating)
select '00000000-0000-4000-8000-000000000001'::uuid, f.id, 'have'::ownership_status, r.rating
from (values
  ('dior|sauvage|edp', 7.5),
  ('parfumsdemarly|layton|edp', 9.0),
  ('armaf|clubdenuitintenseman|edt', 8.0),
  ('lattafa|khamrah|edp', 8.5),
  ('lattafa|asad|edp', 7.0),
  ('lattafa|fakhar|edp', 6.5),
  ('afnan|9pm|edp', 7.0)
) as r(key, rating)
join fragrances f on f.key = r.key
on conflict (user_id, fragrance_id) do nothing;
