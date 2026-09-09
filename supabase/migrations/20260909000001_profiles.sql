-- 0001_profiles.sql
-- Oriv — M1 schema. See AUTH_DESIGN.md §6.
--
-- One table. `readiness_scores` is deliberately NOT created here: it stores health-derived
-- data and must not exist before the sync design does (AUTH_DESIGN.md §6, M5).

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
    id            uuid primary key references auth.users (id) on delete cascade,
    -- May be an Apple private relay address (@privaterelay.appleid.com). Never treat this
    -- as a reachable mailbox, and never key identity on it.
    email         text,
    -- Apple returns the user's name on the FIRST authorization only. If it is missed or
    -- overwritten with null, it is unrecoverable — see the trigger and policy below.
    display_name  text,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

comment on column public.profiles.display_name is
    'Apple supplies this once, on first authorization. Never overwrite a non-null value with null.';

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;

-- A user may read only their own row.
create policy profiles_select_own
    on public.profiles
    for select
    using (auth.uid() = id);

-- A user may update only their own row.
create policy profiles_update_own
    on public.profiles
    for update
    using (auth.uid() = id)
    with check (auth.uid() = id);

-- No insert policy: rows are created by the trigger below, running as the definer.
-- No delete policy: deletion goes through the delete-account Edge Function, which removes
-- the auth.users row and lets the cascade above do the rest (AUTH_DESIGN.md §8).

-- ---------------------------------------------------------------------------
-- Auto-provision a profile for every new auth user
-- ---------------------------------------------------------------------------
-- Done in the database rather than the client so a profile row can never be missed by a
-- client that crashes between sign-up and its first write.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, email, display_name)
    values (
        new.id,
        new.email,
        nullif(new.raw_user_meta_data ->> 'full_name', '')
    )
    on conflict (id) do nothing;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
    after insert on auth.users
    for each row
    execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Keep updated_at honest
-- ---------------------------------------------------------------------------

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;

create trigger profiles_touch_updated_at
    before update on public.profiles
    for each row
    execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Protect the one-shot display_name
-- ---------------------------------------------------------------------------
-- Enforces the rule at the storage layer, so no future client can destroy a captured name
-- by writing null over it on a repeat sign-in.

create or replace function public.preserve_display_name()
returns trigger
language plpgsql
as $$
begin
    if new.display_name is null and old.display_name is not null then
        new.display_name = old.display_name;
    end if;
    if new.email is null and old.email is not null then
        new.email = old.email;
    end if;
    return new;
end;
$$;

drop trigger if exists profiles_preserve_display_name on public.profiles;

create trigger profiles_preserve_display_name
    before update on public.profiles
    for each row
    execute function public.preserve_display_name();
