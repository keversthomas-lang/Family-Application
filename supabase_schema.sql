-- Schéma initial de l'agenda familial Nôtre
create table public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table public.family_members (
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  created_at timestamptz not null default now(),
  primary key (family_id, user_id)
);

create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  name text not null,
  profile_type text not null default 'child' check (profile_type in ('adult', 'child')),
  color text not null default '#b8d4c4',
  created_at timestamptz not null default now()
);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  title text not null,
  start_at timestamptz not null,
  end_at timestamptz,
  location text,
  profile_id uuid references public.profiles(id) on delete set null,
  responsible_user_id uuid references auth.users(id) on delete set null,
  status text not null default 'to_confirm' check (status in ('to_confirm', 'confirmed', 'cancelled')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index events_family_start_idx on public.events (family_id, start_at);

alter table public.families enable row level security;
alter table public.family_members enable row level security;
alter table public.profiles enable row level security;
alter table public.events enable row level security;

create or replace function public.is_family_member(target_family uuid)
returns boolean language sql security definer set search_path = public as $$
  select exists (
    select 1 from public.family_members
    where family_id = target_family and user_id = auth.uid()
  );
$$;

create policy "members can view their families" on public.families for select using (public.is_family_member(id));
create policy "members can view membership" on public.family_members for select using (user_id = auth.uid() or public.is_family_member(family_id));
create policy "members can view profiles" on public.profiles for select using (public.is_family_member(family_id));
create policy "members can create profiles" on public.profiles for insert with check (public.is_family_member(family_id));
create policy "members can update profiles" on public.profiles for update using (public.is_family_member(family_id));
create policy "members can view events" on public.events for select using (public.is_family_member(family_id));
create policy "members can create events" on public.events for insert with check (public.is_family_member(family_id) and created_by = auth.uid());
create policy "members can update events" on public.events for update using (public.is_family_member(family_id));
create policy "members can delete events" on public.events for delete using (public.is_family_member(family_id));

alter publication supabase_realtime add table public.events;
