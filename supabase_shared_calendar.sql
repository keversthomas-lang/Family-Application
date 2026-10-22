-- Partage du calendrier par lien secret, sans compte utilisateur.
-- À exécuter une seule fois dans Supabase > SQL Editor > New query.
-- Une personne qui possède le lien peut lire, ajouter, modifier et supprimer
-- les rendez-vous de cette famille. Les tables ne sont pas exposées en accès direct.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

alter table public.events
  add column if not exists recurrence text not null default 'Keine Wiederholung';

alter table public.events
  alter column created_by drop not null;

create table if not exists public.shared_calendar_links (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

alter table public.shared_calendar_links enable row level security;
revoke all on table public.shared_calendar_links from anon, authenticated;
revoke all on table public.events, public.families, public.profiles from anon, authenticated;
grant usage on schema public to anon, authenticated;

create or replace function public.shared_calendar_bootstrap(p_token text, p_family_name text default 'Familie Kevers')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_family_id uuid;
begin
  if p_token is null or length(p_token) < 40 or p_token !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'Invalid calendar token';
  end if;
  v_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'), 'hex');
  select l.family_id into v_family_id
  from public.shared_calendar_links l
  where l.token_hash = v_hash and l.revoked_at is null;
  if v_family_id is null then
    insert into public.families(name) values (coalesce(nullif(pg_catalog.btrim(p_family_name), ''), 'Familie Kevers'))
    returning id into v_family_id;
    insert into public.profiles(family_id, name, profile_type, color) values
      (v_family_id, 'Thomas', 'adult', '#d58e72'),
      (v_family_id, 'Minyao', 'adult', '#8ba897'),
      (v_family_id, 'Noe', 'child', '#b9a4d4'),
      (v_family_id, 'Mia', 'child', '#e0bd72');
    insert into public.shared_calendar_links(family_id, token_hash) values (v_family_id, v_hash);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.shared_calendar_read(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_family_id uuid;
  v_result jsonb;
begin
  if p_token is null or length(p_token) < 40 or p_token !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'Invalid calendar token';
  end if;
  v_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'), 'hex');
  select l.family_id into v_family_id
  from public.shared_calendar_links l
  where l.token_hash = v_hash and l.revoked_at is null;
  if v_family_id is null then raise exception 'Calendar link is invalid or revoked'; end if;
  select jsonb_build_object(
    'family', (select jsonb_build_object('id', f.id, 'name', f.name) from public.families f where f.id = v_family_id),
    'profiles', coalesce((select jsonb_agg(jsonb_build_object('name', p.name, 'type', p.profile_type, 'color', p.color) order by p.created_at)
      from public.profiles p where p.family_id = v_family_id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object(
      'id', e.id, 'title', e.title, 'person', coalesce(p.name, 'Alle'),
      'start', e.start_at, 'end', e.end_at, 'date', e.start_at,
      'place', e.location, 'recurrence', coalesce(e.recurrence, 'Keine Wiederholung')
    ) order by e.start_at) from public.events e left join public.profiles p on p.id = e.profile_id
      where e.family_id = v_family_id and e.status <> 'cancelled'), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.shared_calendar_save(
  p_token text, p_event_id uuid, p_title text, p_person text,
  p_start timestamptz, p_end timestamptz, p_location text, p_recurrence text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_family_id uuid;
  v_profile_id uuid;
  v_event_id uuid := coalesce(p_event_id, gen_random_uuid());
begin
  if p_token is null or length(p_token) < 40 or p_token !~ '^[A-Za-z0-9_-]+$' then raise exception 'Invalid calendar token'; end if;
  if p_title is null or pg_catalog.length(pg_catalog.btrim(p_title)) = 0 or pg_catalog.length(p_title) > 200 then raise exception 'Enter a title (maximum 200 characters)'; end if;
  if p_start is null or p_end is null or p_end <= p_start then raise exception 'End must be after start'; end if;
  v_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'), 'hex');
  select l.family_id into v_family_id from public.shared_calendar_links l where l.token_hash = v_hash and l.revoked_at is null;
  if v_family_id is null then raise exception 'Calendar link is invalid or revoked'; end if;
  if coalesce(p_person, 'Alle') <> 'Alle' then
    select p.id into v_profile_id from public.profiles p where p.family_id = v_family_id and p.name = p_person;
    if v_profile_id is null then raise exception 'Unknown family member'; end if;
  end if;
  update public.events set title = pg_catalog.btrim(p_title), start_at = p_start, end_at = p_end,
    location = nullif(pg_catalog.btrim(coalesce(p_location, '')), ''), profile_id = v_profile_id,
    recurrence = coalesce(nullif(p_recurrence, ''), 'Keine Wiederholung'), status = 'confirmed'
    where id = v_event_id and family_id = v_family_id;
  if not found then
    if p_event_id is not null then raise exception 'Event not found in this family'; end if;
    insert into public.events(id, family_id, title, start_at, end_at, location, profile_id, recurrence, status)
      values (v_event_id, v_family_id, pg_catalog.btrim(p_title), p_start, p_end,
        nullif(pg_catalog.btrim(coalesce(p_location, '')), ''), v_profile_id,
        coalesce(nullif(p_recurrence, ''), 'Keine Wiederholung'), 'confirmed');
  end if;
  return v_event_id;
end;
$$;

create or replace function public.shared_calendar_delete(p_token text, p_event_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_family_id uuid;
begin
  if p_token is null or length(p_token) < 40 or p_token !~ '^[A-Za-z0-9_-]+$' then raise exception 'Invalid calendar token'; end if;
  v_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'), 'hex');
  select l.family_id into v_family_id from public.shared_calendar_links l where l.token_hash = v_hash and l.revoked_at is null;
  if v_family_id is null then raise exception 'Calendar link is invalid or revoked'; end if;
  delete from public.events where id = p_event_id and family_id = v_family_id;
  return found;
end;
$$;

revoke all on function public.shared_calendar_bootstrap(text, text) from public, anon, authenticated;
revoke all on function public.shared_calendar_read(text) from public, anon, authenticated;
revoke all on function public.shared_calendar_save(text, uuid, text, text, timestamptz, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.shared_calendar_delete(text, uuid) from public, anon, authenticated;
grant execute on function public.shared_calendar_bootstrap(text, text) to anon, authenticated;
grant execute on function public.shared_calendar_read(text) to anon, authenticated;
grant execute on function public.shared_calendar_save(text, uuid, text, text, timestamptz, timestamptz, text, text) to anon, authenticated;
grant execute on function public.shared_calendar_delete(text, uuid) to anon, authenticated;
