-- Millie's Poguelandia RSVP — run once in Supabase SQL Editor
-- One row per family. Email and phone are each unique (case/format-insensitive),
-- so a second submit with the same contact UPDATES the row instead of duplicating it.

create extension if not exists pgcrypto;

create table if not exists public.rsvps (
  id            uuid primary key default gen_random_uuid(),
  invitee_name  text not null,          -- who the paper invite was given to
  email         text,                   -- stored lowercased/trimmed
  phone         text,                   -- stored as 10 digits
  children      int  not null default 1 check (children between 0 and 10),
  adults        int  not null default 1 check (adults between 1 and 10),
  allergies     text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint rsvps_contact_required check (email is not null or phone is not null)
);

create unique index if not exists rsvps_email_uniq on public.rsvps (email) where email is not null;
create unique index if not exists rsvps_phone_uniq on public.rsvps (phone) where phone is not null;

alter table public.rsvps enable row level security;

-- Anyone with the link can read the list (host asked for an open responses view).
drop policy if exists "rsvps public read" on public.rsvps;
create policy "rsvps public read" on public.rsvps for select to anon, authenticated using (true);

-- No direct insert/update/delete for anon: all writes go through submit_rsvp().

create or replace function public.submit_rsvp(
  p_invitee   text,
  p_email     text,
  p_phone     text,
  p_children  int,
  p_adults    int,
  p_allergies text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email    text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_phone    text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  v_invitee  text := nullif(trim(coalesce(p_invitee, '')), '');
  v_existing public.rsvps%rowtype;
begin
  if v_invitee is null then
    return jsonb_build_object('status','conflict','message','Please tell us whose name is on the invite.');
  end if;
  if v_email is null and v_phone is null then
    return jsonb_build_object('status','conflict','message','Add an email or a phone number so we can keep one RSVP per family.');
  end if;
  if v_phone is not null then
    v_phone := regexp_replace(v_phone, '^1(?=\d{10}$)', '');
    if length(v_phone) <> 10 then
      return jsonb_build_object('status','conflict','message','Use a 10-digit US phone number.');
    end if;
  end if;
  if p_children is null or p_children < 0 or p_children > 10 or p_adults is null or p_adults < 1 or p_adults > 10 then
    return jsonb_build_object('status','conflict','message','Children must be 0–10 and adults 1–10.');
  end if;

  -- Find an existing RSVP by email first, then by phone.
  select * into v_existing from public.rsvps
   where (v_email is not null and email = v_email)
      or (v_phone is not null and phone = v_phone)
   order by (email = v_email) desc nulls last
   limit 1;

  if found then
    begin
      update public.rsvps
         set invitee_name = v_invitee,
             email        = coalesce(v_email, email),
             phone        = coalesce(v_phone, phone),
             children     = p_children,
             adults       = p_adults,
             allergies    = nullif(trim(coalesce(p_allergies,'')), ''),
             updated_at   = now()
       where id = v_existing.id;
    exception when unique_violation then
      return jsonb_build_object('status','conflict','message',
        'That email and phone belong to two different RSVPs. Use the same contact you used before, or reply to whoever gave you the invite.');
    end;
    return jsonb_build_object('status','updated','id',v_existing.id);
  end if;

  insert into public.rsvps (invitee_name, email, phone, children, adults, allergies)
  values (v_invitee, v_email, v_phone, p_children, p_adults, nullif(trim(coalesce(p_allergies,'')), ''))
  returning * into v_existing;

  return jsonb_build_object('status','created','id',v_existing.id);
end;
$$;

revoke all on function public.submit_rsvp(text,text,text,int,int,text) from public;
grant execute on function public.submit_rsvp(text,text,text,int,int,text) to anon, authenticated;
grant select on public.rsvps to anon, authenticated;
