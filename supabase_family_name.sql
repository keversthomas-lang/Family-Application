-- Allow the holder of a shared calendar link to rename that family.
-- Run once in Supabase > SQL Editor. This only updates families.name; events are untouched.
create or replace function public.shared_calendar_set_family_name(
  p_token text,
  p_family_name text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_family_id uuid;
  v_name text := pg_catalog.btrim(coalesce(p_family_name, ''));
begin
  if p_token is null or length(p_token) < 40 or p_token !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'Invalid calendar token';
  end if;
  if v_name = '' or pg_catalog.length(v_name) > 80 then
    raise exception 'Family name must contain 1 to 80 characters';
  end if;
  v_hash := pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'),
    'hex'
  );
  select l.family_id into v_family_id
  from public.shared_calendar_links l
  where l.token_hash = v_hash and l.revoked_at is null;
  if v_family_id is null then
    raise exception 'Calendar link is invalid or revoked';
  end if;
  update public.families set name = v_name where id = v_family_id;
  return v_name;
end;
$$;

revoke all on function public.shared_calendar_set_family_name(text, text) from public, anon, authenticated;
grant execute on function public.shared_calendar_set_family_name(text, text) to anon, authenticated;
