-- ============================================================
-- Parents Questionnaire — Phase 2 schema
-- Run this in Supabase SQL Editor (Dashboard → SQL → New Query)
-- ============================================================

-- ─── Profiles: extends auth.users with app-specific fields ───
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text unique not null,
  full_name   text not null,
  child_name  text not null,
  phone       text,
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.profiles is 'User profiles — extends auth.users with the parent/child info from registration.';

-- ─── Submissions: one row per completed questionnaire ───
create table if not exists public.submissions (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references public.profiles(id) on delete cascade,
  submitted_at       timestamptz not null default now(),
  app_version        text not null default 'v6',
  answers_count      int,
  questions_total    int,
  duration_minutes   int,
  -- Full answers as JSONB — same structure as the JSON we already produce client-side
  answers            jsonb not null,
  -- Auto-detected clinical segments (populated by Phase 3 trigger / function)
  detected_segments  jsonb not null default '[]'::jsonb,
  -- Therapist-side fields
  therapist_notes    text,
  reviewed_at        timestamptz,
  created_at         timestamptz not null default now()
);

comment on table public.submissions is 'Each completed parent questionnaire — answers stored as JSONB for flexibility.';

create index if not exists submissions_user_id_idx     on public.submissions (user_id);
create index if not exists submissions_submitted_at_idx on public.submissions (submitted_at desc);

-- Idempotency: a client-generated key so a double-submit (e.g. offline retry) can't duplicate a row.
alter table public.submissions add column if not exists idempotency_key uuid;
create unique index if not exists submissions_idem_idx on public.submissions (user_id, idempotency_key)
  where idempotency_key is not null;

-- ─── Per-question UX analytics: one row per question per submission ───
create table if not exists public.question_timings (
  id              uuid primary key default gen_random_uuid(),
  submission_id   uuid not null references public.submissions(id) on delete cascade,
  user_id         uuid not null references public.profiles(id)    on delete cascade,
  qid             text,                       -- stable question id (e.g. 'v6:14'); null until Phase 0 adds qids
  flat_id         text not null,              -- client answer key, e.g. 's3_q2'
  number          text,                       -- displayed question number, if any
  dwell_ms        int  not null default 0,    -- total time the question was on screen
  revisit_count   int  not null default 0,    -- times navigated back to it
  answer_changes  int  not null default 0,    -- times the answer value actually changed
  first_seen_at   timestamptz,
  answered_at     timestamptz,
  created_at      timestamptz not null default now()
);

comment on table public.question_timings is 'Per-question dwell/engagement analytics, captured client-side and bulk-inserted at submit time.';

create index if not exists question_timings_submission_idx on public.question_timings (submission_id);
create index if not exists question_timings_qid_idx        on public.question_timings (qid);

-- ─── Row Level Security ───
alter table public.profiles    enable row level security;
alter table public.submissions enable row level security;

-- Helper function: is the current user an admin?
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select is_admin from public.profiles where id = auth.uid()),
    false
  );
$$;

-- ─── Policies: profiles ───
drop policy if exists "Users can view own profile"    on public.profiles;
drop policy if exists "Users can update own profile"  on public.profiles;
drop policy if exists "Admin can view all profiles"   on public.profiles;

create policy "Users can view own profile"
  on public.profiles for select
  using (auth.uid() = id);

create policy "Users can update own profile"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "Admin can view all profiles"
  on public.profiles for select
  using (public.is_admin());

-- ─── Policies: submissions ───
drop policy if exists "Users can insert own submissions" on public.submissions;
drop policy if exists "Users can view own submissions"   on public.submissions;
drop policy if exists "Admin can view all submissions"   on public.submissions;
drop policy if exists "Admin can update submissions"     on public.submissions;

create policy "Users can insert own submissions"
  on public.submissions for insert
  with check (auth.uid() = user_id);

create policy "Users can view own submissions"
  on public.submissions for select
  using (auth.uid() = user_id);

create policy "Admin can view all submissions"
  on public.submissions for select
  using (public.is_admin());

create policy "Admin can update submissions"
  on public.submissions for update
  using (public.is_admin())
  with check (public.is_admin());

-- ─── Policies: question_timings ───
alter table public.question_timings enable row level security;

drop policy if exists "Users can insert own timings" on public.question_timings;
drop policy if exists "Users can view own timings"   on public.question_timings;
drop policy if exists "Admin can view all timings"   on public.question_timings;

create policy "Users can insert own timings"
  on public.question_timings for insert
  with check (auth.uid() = user_id);

create policy "Users can view own timings"
  on public.question_timings for select
  using (auth.uid() = user_id);

create policy "Admin can view all timings"
  on public.question_timings for select
  using (public.is_admin());

-- ─── Trigger: auto-create profile when a new auth.user is created ───
-- Pulls full_name, child_name, phone from raw_user_meta_data
-- (set during signup via supabase.auth.signUp({ data: {...} }))
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, child_name, phone)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name',  ''),
    coalesce(new.raw_user_meta_data->>'child_name', ''),
    coalesce(new.raw_user_meta_data->>'phone',      '')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─── Trigger: bump updated_at on profile updates ───
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ─── Realtime: enable for admin dashboard live updates ───
-- The supabase_realtime publication exists by default; we just add our table.
alter publication supabase_realtime add table public.submissions;

-- ─── Convenience view: admin submissions with user info ───
create or replace view public.submissions_with_user as
  select
    s.*,
    p.full_name     as parent_name,
    p.child_name    as child_name,
    p.email         as parent_email,
    p.phone         as parent_phone
  from public.submissions s
  join public.profiles p on p.id = s.user_id;

comment on view public.submissions_with_user is 'Admin-friendly view joining submission + parent info.';

-- ============================================================
-- Live questionnaire drafts — server-side progress + partial answers
-- Enables: (1) admin funnel visibility (registered/started/in-progress/
-- abandoned/submitted + drop-off point) and (2) FULL real-time visibility
-- into every answer a customer gives, from the moment they START — before
-- they submit. One row per user, upserted (debounced) by the client.
-- Append-only; safe to re-run.
-- ============================================================

create table if not exists public.submission_drafts (
  user_id         uuid primary key references public.profiles(id) on delete cascade,
  status          text        not null default 'in_progress',   -- in_progress | submitted
  -- Full partial answers, SAME structure as submissions.answers (buildSubmissionPayload)
  answers         jsonb       not null default '{}'::jsonb,
  answered_count  int         not null default 0,
  current_index   int         not null default 0,                -- FLAT index (incl. intros/breaks)
  last_qid        text,                                          -- furthest question reached (drop-off)
  total_questions int,
  started_at      timestamptz not null default now(),
  last_active_at  timestamptz not null default now(),
  app_version     text
);

comment on table public.submission_drafts is 'Live questionnaire draft per user: partial answers + progress, for admin funnel and full real-time answer visibility before submit.';

create index if not exists submission_drafts_status_idx      on public.submission_drafts (status);
create index if not exists submission_drafts_last_active_idx on public.submission_drafts (last_active_at desc);

alter table public.submission_drafts enable row level security;

drop policy if exists "Users insert own draft" on public.submission_drafts;
drop policy if exists "Users update own draft" on public.submission_drafts;
drop policy if exists "Users view own draft"   on public.submission_drafts;
drop policy if exists "Admin can view all drafts" on public.submission_drafts;

create policy "Users insert own draft"
  on public.submission_drafts for insert
  with check (auth.uid() = user_id);

create policy "Users update own draft"
  on public.submission_drafts for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users view own draft"
  on public.submission_drafts for select
  using (auth.uid() = user_id);

-- Admin sees every live draft (this is the "full transparency" requirement).
create policy "Admin can view all drafts"
  on public.submission_drafts for select
  using (public.is_admin());

-- ─── Trigger: when a submission lands, flip the user's draft to 'submitted' ───
-- Runs SECURITY DEFINER so it works regardless of who inserts, and covers
-- offline submissions that sync later.
create or replace function public.mark_draft_submitted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.submission_drafts
     set status = 'submitted', last_active_at = now()
   where user_id = new.user_id;
  return new;
end;
$$;

drop trigger if exists on_submission_mark_draft on public.submissions;
create trigger on_submission_mark_draft
  after insert on public.submissions
  for each row execute function public.mark_draft_submitted();

-- ─── Admin funnel overview (admin-only via is_admin guard) ───
create or replace function public.admin_funnel_overview()
returns table (
  registered          bigint,
  started             bigint,
  in_progress_active  bigint,
  abandoned           bigint,
  submitted           bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    (select count(*) from public.profiles),
    (select count(*) from public.submission_drafts),
    (select count(*) from public.submission_drafts
        where status = 'in_progress' and last_active_at >= now() - interval '24 hours'),
    (select count(*) from public.submission_drafts
        where status = 'in_progress' and last_active_at <  now() - interval '24 hours'),
    (select count(*) from public.submission_drafts where status = 'submitted')
  where public.is_admin();
$$;

-- ─── Drop-off histogram: where in-progress users are currently stuck ───
create or replace function public.admin_dropoff()
returns table ( last_qid text, n bigint )
language sql
stable
security definer
set search_path = public
as $$
  select last_qid, count(*)::bigint as n
  from public.submission_drafts
  where public.is_admin()
    and status = 'in_progress'
    and last_qid is not null
  group by last_qid
  order by n desc;
$$;

grant execute on function public.admin_funnel_overview() to authenticated;
grant execute on function public.admin_dropoff()         to authenticated;

-- ─── Admin-friendly view: drafts joined with parent info (RLS-respecting) ───
create or replace view public.drafts_with_user
  with (security_invoker = true) as
  select
    d.*,
    p.full_name  as parent_name,
    p.child_name as child_name,
    p.email      as parent_email,
    p.phone      as parent_phone
  from public.submission_drafts d
  join public.profiles p on p.id = d.user_id;

comment on view public.drafts_with_user is 'Admin-friendly view joining live drafts + parent info. security_invoker so RLS (admin-only select) applies.';

-- ============================================================
-- Full in-app admin dashboard: central submissions view, user management
-- (promote/demote admin), and an audit log of admin actions.
-- Append-only; safe to re-run.
-- ============================================================

-- (a) SECURITY FIX: the original submissions_with_user view (defined earlier in
-- this file) runs with the view-owner's rights and therefore BYPASSES RLS — any
-- authenticated user could read every submission through it. Recreate it
-- security_invoker so RLS applies (admin sees all; a parent sees only their own).
create or replace view public.submissions_with_user
  with (security_invoker = true) as
  select
    s.*,
    p.full_name  as parent_name,
    p.child_name as child_name,
    p.email      as parent_email,
    p.phone      as parent_phone
  from public.submissions s
  join public.profiles p on p.id = s.user_id;

-- (b) Promote / demote an admin (admin-only; blocks self-demotion to avoid lockout).
create or replace function public.admin_set_admin(target uuid, make_admin boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  if make_admin = false and target = auth.uid() then
    raise exception 'cannot remove your own admin role';
  end if;
  update public.profiles set is_admin = make_admin where id = target;
  insert into public.admin_access_log (admin_id, action, target_user_id, meta)
    values (auth.uid(), 'set_admin', target, jsonb_build_object('make_admin', make_admin));
end;
$$;
grant execute on function public.admin_set_admin(uuid, boolean) to authenticated;

-- (c) Users overview for the admin user-management list (RLS-respecting).
create or replace view public.users_overview
  with (security_invoker = true) as
  select
    p.id, p.full_name, p.child_name, p.email, p.phone, p.is_admin, p.created_at,
    d.status         as draft_status,
    d.answered_count as draft_answered_count,
    d.total_questions,
    d.last_active_at,
    (select count(*) from public.submissions s where s.user_id = p.id) as submissions_count
  from public.profiles p
  left join public.submission_drafts d on d.user_id = p.id;

comment on view public.users_overview is 'Admin user-management list: profile + draft status + submission count. security_invoker so RLS applies.';

-- (d) Audit log: admin views of submissions/drafts + admin-role changes.
create table if not exists public.admin_access_log (
  id                uuid primary key default gen_random_uuid(),
  admin_id          uuid references public.profiles(id) on delete set null,
  action            text not null,            -- view_submission | view_draft | set_admin
  target_user_id    uuid,
  target_submission uuid,
  meta              jsonb,
  created_at        timestamptz not null default now()
);
create index if not exists admin_access_log_created_idx on public.admin_access_log (created_at desc);

alter table public.admin_access_log enable row level security;
drop policy if exists "Admin reads audit log" on public.admin_access_log;
create policy "Admin reads audit log"
  on public.admin_access_log for select
  using (public.is_admin());

create or replace function public.log_admin_access(
  action text,
  target_user uuid,
  target_submission uuid default null,
  meta jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  insert into public.admin_access_log (admin_id, action, target_user_id, target_submission, meta)
    values (auth.uid(), action, target_user, target_submission, meta);
end;
$$;
grant execute on function public.log_admin_access(text, uuid, uuid, jsonb) to authenticated;

-- ─── DONE ───
-- Next steps:
-- 1. Create your admin account via the app (Supabase Auth signup)
-- 2. In SQL Editor, run: update public.profiles set is_admin = true where email = 'your-admin@email.com';
-- 3. Re-login to the app to refresh your JWT — admin view will appear.
