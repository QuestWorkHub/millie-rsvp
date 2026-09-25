-- Millie's Poguelandia RSVP — migration 002 (run once in Supabase SQL Editor, after 001)
-- 1) Adds a Questions / Notes field to RSVPs.
-- 2) Hides email + phone from the public list (they were readable with the public key).
-- 3) Adds admin_rsvps(): full guest list incl. contact info, only for the host's login.

-- 1) Notes column --------------------------------------------------------------
alter table public.rsvps add column if not exists notes text;

-- 2) Public can read only the non-contact columns --------------------------------
revoke select on public.rsvps from anon, authenticated;
grant select (invitee_name, children, adults, allergies, created_at, updated_at)
  on public.rsvps to anon, authenticated;

-- submit_rsvp gains p_notes. It defaults to null so the page that's live right now
-- keeps working between running this migration and pushing the new page.
drop function if exists public.submit_rsvp(text,text,text,int,int,text);

create or replace function public.submit_rsvp(
  p_invitee   text,
  p_email     text,
  p_phone     text,
  p_children  int,
  p_adults    int,
  p_allergies text,
  p_notes     text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email    text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_phone    text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  v_invitee  text := nullif(trim(coalesce(p_invitee, '')), '');
  v_notes    text := nullif(trim(coalesce(p_notes, '')), '');
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
  if v_notes is not null and length(v_notes) > 2000 then
    return jsonb_build_object('status','conflict','message','Questions / notes can be up to 2,000 characters — please shorten it a bit.');
  end if;

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
             notes        = case when p_notes is null then notes else v_notes end, -- old page (no notes field) never wipes a note
             updated_at   = now()
       where id = v_existing.id;
    exception when unique_violation then
      return jsonb_build_object('status','conflict','message',
        'That email and phone belong to two different RSVPs. Use the same contact you used before, or call/text Kameron at 425.377.3977.');
    end;
    return jsonb_build_object('status','updated','id',v_existing.id);
  end if;

  insert into public.rsvps (invitee_name, email, phone, children, adults, allergies, notes)
  values (v_invitee, v_email, v_phone, p_children, p_adults, nullif(trim(coalesce(p_allergies,'')), ''), v_notes)
  returning * into v_existing;

  return jsonb_build_object('status','created','id',v_existing.id);
end;
$$;

revoke all on function public.submit_rsvp(text,text,text,int,int,text,text) from public;
grant execute on function public.submit_rsvp(text,text,text,int,int,text,text) to anon, authenticated;

-- 3) Host-only full list ------------------------------------------------------------
-- Works only when signed in as the host account (created in Authentication → Users).
create or replace function public.admin_rsvps()
returns setof public.rsvps
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(lower(auth.jwt() ->> 'email'), '') <> 'kbeal033@gmail.com' then
    raise exception 'This list is only available to the host account.' using errcode = '42501';
  end if;
  return query select * from public.rsvps order by created_at desc;
end;
$$;

revoke all on function public.admin_rsvps() from public;
grant execute on function public.admin_rsvps() to authenticated;

notify pgrst, 'reload schema';
