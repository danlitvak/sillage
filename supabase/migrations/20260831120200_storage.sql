-- Bottle photos: one bucket, partitioned by user id in the object path.
--
-- =============================================================================
-- WHY THE PHOTOS ARE THE USER'S OWN
-- =============================================================================
-- The shelf shows the bottle the user actually photographed rather than a stock
-- product image. That is a better product — a shelf that looks like their shelf
-- — and it sidesteps the licensing question that stock bottle photography would
-- raise for an app that might one day be public.

insert into storage.buckets (id, name, public)
values ('bottle-photos', 'bottle-photos', true)
on conflict (id) do nothing;

-- =============================================================================
-- THE PATH PREFIX IS THE AUTHORISATION
-- =============================================================================
-- Every policy below keys on the FIRST path segment being the caller's user id,
-- which is why `uploadBottlePhoto` in lib/data/repository.dart builds the path
-- as `<uid>/<filename>` rather than letting a caller choose it. A photo written
-- anywhere else is rejected by the database, not merely discouraged by the
-- client.
--
-- `storage.foldername(name)` returns the path segments; [1] is the first.

create policy "own bottle photos: read"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'bottle-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "own bottle photos: insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'bottle-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "own bottle photos: update"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'bottle-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "own bottle photos: delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'bottle-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- NOTE ON `public = true`.
--
-- The bucket is public so `getPublicUrl` works without minting a signed URL for
-- every tile on the shelf — with a grid of thirty bottles that is thirty round
-- trips before anything renders.
--
-- The tradeoff is real and worth stating plainly: object paths are
-- unguessable-ish (a uuid folder plus a millisecond timestamp) but they are NOT
-- secret, so anyone holding a URL can fetch that photo. For photographs of
-- fragrance bottles that is an acceptable trade. If this ever stores anything
-- personal, flip `public` to false and switch `publicPhotoUrl` to
-- `createSignedUrl` — the policies above already restrict listing and writing
-- either way.
