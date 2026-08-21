# Deploying the `church` schema

Runbook for applying the Members + Kids Ministry migrations to the hosted
project `oyewjuvpnavwhmdiqfve`. Read it before running anything — step 0 is not
optional, because the local migration tree does **not** describe the live
database.

## Why this needs care

Replaying all 45 pre-existing migrations against a clean Postgres shows:

| Migration | Fails with |
|---|---|
| `20251130000004_create_allocation_requests.sql` | `column "app_role" does not exist` |
| `20251130200000_fix_allocation_request_update_policy.sql` | same |
| `20251130210000_add_allocation_period_amounts.sql` | same |
| `20251125000000_add_multi_tenancy.sql` | `policy ... already exists` (not replayable) |

The column on `user_organizations` is `role`, not `app_role`, and `superadmin`
is not a value of the `app_role` enum. Those three scripts **cannot ever have
run to completion**. Postgres autocommits per statement, so they partially
applied: tables created, policies not.

Confirmed against production (read-only, via PostgREST): all four allocation
tables **do** exist. So production was repaired by hand at some point and its
migration history does not match this tree.

There are also two duplicate migration timestamps: `20251130220000` and
`20260228000000`.

## Step 0 — reconcile (no writes to the schema)

```bash
npx supabase login                       # opens a browser
npx supabase link --project-ref oyewjuvpnavwhmdiqfve
npx supabase migration list --linked     # compare Local vs Remote
```

Expect gaps. For every local migration that the remote does not list but which
is already reflected in the live schema, record it as applied **without
re-running it**:

```bash
npx supabase migration repair --status applied 20251130000004
npx supabase migration repair --status applied 20251130200000
npx supabase migration repair --status applied 20251130210000
```

> `migration repair` writes to `supabase_migrations.schema_migrations` on the
> remote. It changes bookkeeping only, never the schema — but it is a write, so
> confirm the list output first.

Do not proceed until `migration list` shows Local and Remote in agreement for
everything before `20260320000000`.

## Step 1 — back up

Confirm a recent automatic backup exists (Dashboard → Database → Backups), or
take one. The migrations are overwhelmingly additive — 41 new tables in a new
schema — but three touch existing objects:

| Migration | Touches |
|---|---|
| `20260320000000` | Replaces `public.handle_new_user()` |
| `20260320000500` | Replaces `public.sync_ministry_from_profile()`; adds a UNIQUE constraint to `budget.ministries` |
| `20260320000700` | Adds a UNIQUE constraint to `public.rooms` |

Both replaced functions preserve existing behaviour for existing cases; the
constraints are redundant with each table's primary key and exist so composite
foreign keys can reference them.

## Step 2 — apply

```bash
npx supabase db push
```

Applies the `20260320*` migrations. Every one has been verified to run
cleanly against Postgres 15 from a clean slate.

## Step 3 — expose the schema (REQUIRED, and easy to miss)

Production currently exposes:

```
public, graphql_public, inventory, budget
```

**Add `church`** in Dashboard → Settings → API → Exposed schemas.

`supabase/config.toml` governs local development only; it does not push this
setting. Until `church` is added there, every `supabase.schema("church")` call
returns `404 PGRST106` and the entire Members module looks broken while the
tables exist and are perfectly healthy.

> ### DO NOT run `supabase config push` to do this
>
> It pushes the WHOLE of `config.toml`, not just `[api] schemas`. This file
> carries local development values:
>
> ```toml
> site_url = "http://127.0.0.1:3000"
> additional_redirect_urls = ["https://localhost:3000"]
> ```
>
> Pushing that would overwrite the production Site URL with localhost and wipe
> the redirect allowlist, breaking password resets and email confirmation links
> for every user. `SUPABASE_AUTH_CONFIG.md` documents the correct production
> value as `https://addislidet.info`.
>
> Either change the exposed schemas by hand in the Dashboard, or reconcile the
> whole of `config.toml` with production first. The Dashboard is a checkbox;
> the alternative is a support incident.

## Step 4 — enable Realtime for the live classroom roster

`20260320001000` attempts this and skips with a NOTICE if the publication is
absent. Verify it took:

```sql
SELECT schemaname, tablename FROM pg_publication_tables
WHERE pubname = 'supabase_realtime' AND schemaname = 'church';
```

If empty:

```sql
ALTER PUBLICATION supabase_realtime ADD TABLE church.kids_check_ins;
ALTER TABLE church.kids_check_ins REPLICA IDENTITY FULL;
```

## Step 5 — regenerate types

```bash
npx supabase gen types typescript --project-id oyewjuvpnavwhmdiqfve \
  --schema public --schema budget --schema church \
  > src/integrations/supabase/types.ts
```

The `church` block in `types.ts` is currently generated from a local container
with the same migrations. Regenerating from production will also pull in the
real `public`/`budget` shapes, which are stale in that file — expect a large
diff and some existing type errors in the budget module to change.

## Step 6 — verify

```sql
-- every church table must have RLS AND at least one policy
SELECT c.relname, c.relrowsecurity,
       (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'church' AND c.relkind = 'r'
ORDER BY 1;

-- anon must have NO privileges in church
SELECT count(*) FROM information_schema.role_table_grants
WHERE table_schema = 'church' AND grantee = 'anon';   -- expect 0

-- the PIN and credential vaults must be unreachable by authenticated
SELECT table_name, grantee FROM information_schema.role_table_grants
WHERE table_schema = 'church'
  AND table_name IN ('kids_volunteer_pins','kids_shift_tokens',
                     'kids_check_in_secrets','crypto_config')
  AND grantee IN ('anon','authenticated');            -- expect 0 rows
```

## Step 7 — post-deploy setup (non-code, blocking for Kids)

1. **Create classrooms for VA-Springfield.** Every existing `public.rooms` row
   was assigned to MD in `20251125000000`; the VA branch has none.
2. **Set age-band boundaries per classroom** in `church.room_kids_config`. The
   seeded bands are a starting point and decide which classroom a child is sent
   to — review them with the Kids Ministry director before go-live.
3. **Provision station accounts** through the Admin API with
   `raw_app_meta_data = {"account_type":"station"}`, so `handle_new_user` gives
   them a profile and no organization membership.
4. **Grant module permissions** by inserting into `church.module_grants`
   (`kids_admin`, `members_admin`, `kids_volunteer`, ...). Org admins already
   have everything implicitly.
5. **Set volunteer PINs** via `church.set_volunteer_pin(volunteer_id, pin)`.
6. **Enable `pg_cron`** (Dashboard → Database → Extensions). Two jobs depend on
   it: `send-kids-notifications` (every minute, `20260320002100`) and
   `kids-session-tick` (every ten minutes, `20260320010000`). The second is what
   opens Sunday's session on its own; without the extension both migrations skip
   with a NOTICE and every session has to be opened by hand. Verify:

   ```sql
   SELECT jobname, schedule, active FROM cron.job
   WHERE jobname IN ('send-kids-notifications', 'kids-session-tick');
   ```

7. **Check the service times** in `church.kids_events`. They are seeded from the
   published schedule — Silver Spring 11:00, Springfield 10:30, both 150
   minutes — and check-in opens `check_in_opens_minutes_before` (45) earlier. If
   a branch moves its service, change the row; there is no second place to edit.

   ```sql
   SELECT o.slug, e.auto_open_dow, e.service_starts_local, e.service_minutes
   FROM church.kids_events e JOIN public.organizations o ON o.id = e.organization_id;
   ```

## Known issues NOT fixed by this deploy

1. **`public.user_organizations` has two recursive RLS policies** (from
   `20251125000000`): their `USING` clause subqueries `user_organizations`
   itself. On a clean replay this makes the table unreadable for any
   authenticated user, cascading to `rooms`, `events` and all of `budget`.
   `20251125000003` was written to fix this but drops four policy names that do
   not include the recursive one. Production evidently differs; worth
   confirming, because it is a live foot-gun.
2. **`anon` holds `GRANT ALL` on the `budget` schema**, including
   `ALTER DEFAULT PRIVILEGES` for future tables (`20251130000002`). Verified
   read-only against production: RLS currently blocks anonymous reads, so this
   is latent rather than exploitable — but the grant should be narrowed.
3. **The `expense-attachments` bucket** SELECT policy is
   `USING (bucket_id = 'expense-attachments')` — any authenticated user can
   read any receipt.

The new `church` schema avoids all three: no `anon` grants, policies built on
`SECURITY DEFINER` helpers rather than inline subqueries on
`user_organizations`, and no storage bucket yet.
