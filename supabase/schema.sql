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

-- ─── DONE ───
-- Next steps:
-- 1. Create your admin account via the app (Supabase Auth signup)
-- 2. In SQL Editor, run: update public.profiles set is_admin = true where email = 'your-admin@email.com';
-- 3. Re-login to the app to refresh your JWT — admin view will appear.
