-- Import Google Calendar (lecture seule côté Google) vers le calendrier familial.
-- Exécuter après supabase_shared_calendar.sql dans Supabase > SQL Editor.
-- Chaque événement est identifié par le compte Google et l'ID Google afin que
-- les imports suivants mettent à jour l'événement existant au lieu de le dupliquer.

create table if not exists public.google_calendar_imports (
  family_id uuid not null references public.families(id) on delete cascade,
  google_account_email text not null,
  google_event_id text not null,
  event_id uuid not null unique references public.events(id) on delete cascade,
  updated_at timestamptz not null default now(),
  primary key (family_id, google_account_email, google_event_id)
);

alter table public.google_calendar_imports enable row level security;
revoke all on table public.google_calendar_imports from anon, authenticated;

create or replace function public.shared_calendar_import_google_event(
  p_token text,
  p_google_account_email text,
  p_google_event_id text,
  p_title text,
  p_start timestamptz,
  p_end timestamptz,
  p_location text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_family_id uuid;
  v_event_id uuid;
  v_title text;
begin
  if p_token is null or length(p_token) < 40 or p_token !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'Invalid calendar token';
  end if;
  if p_google_account_email is null or length(pg_catalog.btrim(p_google_account_email)) > 320 then
    raise exception 'Invalid Google account';
  end if;
  if p_google_event_id is null or length(p_google_event_id) = 0 or length(p_google_event_id) > 512 then
    raise exception 'Invalid Google event ID';
  end if;
  v_title := coalesce(nullif(pg_catalog.btrim(p_title), ''), 'Google-Termin');
  if length(v_title) > 200 then raise exception 'Event title is too long'; end if;
  if p_start is null or p_end is null or p_end <= p_start then raise exception 'End must be after start'; end if;

  v_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'), 'hex');
  select l.family_id into v_family_id
  from public.shared_calendar_links l
  where l.token_hash = v_hash and l.revoked_at is null;
  if v_family_id is null then raise exception 'Calendar link is invalid or revoked'; end if;

  select i.event_id into v_event_id
  from public.google_calendar_imports i
  where i.family_id = v_family_id
    and i.google_account_email = pg_catalog.lower(pg_catalog.btrim(p_google_account_email))
    and i.google_event_id = p_google_event_id;

  if v_event_id is null then
    v_event_id := extensions.gen_random_uuid();
    insert into public.events(id, family_id, title, start_at, end_at, location, profile_id, recurrence, status)
    values (v_event_id, v_family_id, v_title, p_start, p_end,
      nullif(pg_catalog.btrim(coalesce(p_location, '')), ''), null,
      'Keine Wiederholung', 'confirmed');
    insert into public.google_calendar_imports(family_id, google_account_email, google_event_id, event_id)
    values (v_family_id, pg_catalog.lower(pg_catalog.btrim(p_google_account_email)), p_google_event_id, v_event_id);
  else
    update public.events set title = v_title, start_at = p_start, end_at = p_end,
      location = nullif(pg_catalog.btrim(coalesce(p_location, '')), ''),
      profile_id = null, recurrence = 'Keine Wiederholung', status = 'confirmed'
    where id = v_event_id and family_id = v_family_id;
    if not found then
      v_event_id := extensions.gen_random_uuid();
      insert into public.events(id, family_id, title, start_at, end_at, location, profile_id, recurrence, status)
      values (v_event_id, v_family_id, v_title, p_start, p_end,
        nullif(pg_catalog.btrim(coalesce(p_location, '')), ''), null,
        'Keine Wiederholung', 'confirmed');
      update public.google_calendar_imports set event_id = v_event_id, updated_at = now()
      where family_id = v_family_id
        and google_account_email = pg_catalog.lower(pg_catalog.btrim(p_google_account_email))
        and google_event_id = p_google_event_id;
    else
      update public.google_calendar_imports set updated_at = now()
      where family_id = v_family_id
        and google_account_email = pg_catalog.lower(pg_catalog.btrim(p_google_account_email))
        and google_event_id = p_google_event_id;
    end if;
  end if;
  return v_event_id;
end;
$$;

revoke all on function public.shared_calendar_import_google_event(text, text, text, text, timestamptz, timestamptz, text) from public, anon, authenticated;
grant execute on function public.shared_calendar_import_google_event(text, text, text, text, timestamptz, timestamptz, text) to anon, authenticated;
