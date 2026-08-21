-- =============================================================================
-- PLACEFLIX — Supabase schema
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run more than once.
-- =============================================================================

-- ---------- tables -----------------------------------------------------------

create table if not exists public.settings (
  id            smallint primary key default 1,
  tagline       text,
  instructions  jsonb   default '[]'::jsonb,
  bg_id         text    default 'studio-light',
  scrim         numeric default 0.55,
  pass_mark     int     default 60,
  duration_min  int     default 30,
  quotes        jsonb   default '{}'::jsonb,
  featured      jsonb   default '[]'::jsonb,
  gallery       jsonb   default '[]'::jsonb,
  updated_at    timestamptz default now(),
  constraint settings_singleton check (id = 1)
);
insert into public.settings (id) values (1) on conflict (id) do nothing;

-- The answer key lives here and is never sent to a student's browser.
create table if not exists public.questions (
  id       bigint generated always as identity primary key,
  ord      int  not null default 0,
  section  text not null default 'General',
  prompt   text not null,
  options  jsonb not null,
  answer   int  not null
);

create table if not exists public.applicants (
  id             text primary key,
  full_name      text not null,
  email          text not null,
  college        text not null,
  stream         text not null,
  year           text not null,
  registered_at  timestamptz not null default now(),
  agreed_at      timestamptz,
  status         text not null default 'registered',
  submitted_at   timestamptz,
  auto_submitted boolean not null default false,
  score          int,
  total          int,
  percent        int,
  answers        jsonb,
  marks          jsonb,
  breakdown      jsonb,
  released       boolean not null default false,
  released_at    timestamptz
);
create index if not exists applicants_email_idx on public.applicants (lower(email));

-- ---------- row-level security ----------------------------------------------
-- Signed-in admins get full access. The public gets none: students never touch
-- these tables directly, only the four functions further down.

alter table public.settings   enable row level security;
alter table public.questions  enable row level security;
alter table public.applicants enable row level security;

drop policy if exists "admins manage settings"   on public.settings;
drop policy if exists "admins manage questions"  on public.questions;
drop policy if exists "admins manage applicants" on public.applicants;

create policy "admins manage settings"   on public.settings
  for all to authenticated using (true) with check (true);
create policy "admins manage questions"  on public.questions
  for all to authenticated using (true) with check (true);
create policy "admins manage applicants" on public.applicants
  for all to authenticated using (true) with check (true);

-- ---------- what the public is allowed to do --------------------------------

-- Page settings (background, headline, cut-off, instructions).
create or replace function public.get_settings()
returns jsonb
language sql security definer set search_path = public as $$
  select to_jsonb(s) - 'updated_at' from public.settings s where s.id = 1;
$$;

-- The paper WITHOUT the answer key. This is the only question data a student
-- can obtain, so opening DevTools reveals nothing useful.
create or replace function public.get_paper()
returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('s', section, 'q', prompt, 'o', options)
              order by ord, id), '[]'::jsonb)
  from public.questions;
$$;

-- Registration. Returns the existing application if the email is already known,
-- so nobody can accidentally register twice.
create or replace function public.register_applicant(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  existing public.applicants%rowtype;
  new_id   text;
  q_count  int;
begin
  select * into existing from public.applicants
   where lower(email) = lower(p->>'email') limit 1;

  if found then
    return jsonb_build_object('id', existing.id, 'status', existing.status, 'existing', true);
  end if;

  select count(*) into q_count from public.questions;

  new_id := 'PFX-' || to_char(now(), 'YY') || '-' ||
            lpad(((select count(*) from public.applicants) + 1)::text, 3, '0') ||
            upper(substr(md5(random()::text), 1, 3));

  insert into public.applicants
    (id, full_name, email, college, stream, year, agreed_at, total)
  values
    (new_id, p->>'fullName', p->>'email', p->>'college',
     p->>'stream', p->>'year', now(), q_count);

  return jsonb_build_object('id', new_id, 'status', 'registered', 'existing', false);
end $$;

-- Marking happens here, on the server, after the paper is handed in.
-- A student cannot change their own score.
create or replace function public.submit_test(p_id text, p_answers jsonb, p_auto boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  rec       public.applicants%rowtype;
  q         record;
  n_total   int := 0;
  n_score   int := 0;
  idx       int := 0;
  v_marks   jsonb := '[]'::jsonb;
  v_break   jsonb;
begin
  select * into rec from public.applicants where id = p_id;
  if not found then
    raise exception 'Unknown application id';
  end if;
  if rec.status = 'submitted' then
    return jsonb_build_object('already', true, 'score', rec.score,
                              'total', rec.total, 'percent', rec.percent);
  end if;

  select count(*) into n_total from public.questions;

  for q in select answer from public.questions order by ord, id loop
    if (p_answers ->> idx) is not null and (p_answers ->> idx)::int = q.answer then
      n_score := n_score + 1;
      v_marks := v_marks || 'true'::jsonb;
    else
      v_marks := v_marks || 'false'::jsonb;
    end if;
    idx := idx + 1;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('sec', section, 'got', got, 'of', cnt)
                            order by first_rn), '[]'::jsonb)
    into v_break
  from (
    select section,
           count(*)::int as cnt,
           count(*) filter (
             where (p_answers ->> ((rn - 1)::int)) is not null
               and (p_answers ->> ((rn - 1)::int))::int = answer
           )::int as got,
           min(rn) as first_rn
    from (
      select answer, section, row_number() over (order by ord, id) as rn
      from public.questions
    ) numbered
    group by section
  ) grouped;

  update public.applicants set
    status         = 'submitted',
    submitted_at   = now(),
    auto_submitted = p_auto,
    answers        = p_answers,
    marks          = v_marks,
    breakdown      = v_break,
    score          = n_score,
    total          = n_total,
    percent        = case when n_total > 0 then round(n_score * 100.0 / n_total) else 0 end
  where id = p_id
  returning * into rec;

  return jsonb_build_object('ok', true, 'score', rec.score,
                            'total', rec.total, 'percent', rec.percent);
end $$;

-- A student looking up their own result. The score is withheld until an admin
-- releases it, and one row is only ever returned for a matching id + email.
create or replace function public.get_status(p_id text, p_email text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  rec public.applicants%rowtype;
  out_json jsonb;
begin
  select * into rec from public.applicants
   where upper(id) = upper(trim(p_id))
     and lower(email) = lower(trim(p_email));
  if not found then
    return null;
  end if;

  out_json := jsonb_build_object(
    'id', rec.id, 'fullName', rec.full_name, 'email', rec.email,
    'college', rec.college, 'stream', rec.stream, 'year', rec.year,
    'status', rec.status, 'registeredAt', rec.registered_at,
    'submittedAt', rec.submitted_at, 'released', rec.released,
    'releasedAt', rec.released_at, 'total', rec.total);

  if rec.released then
    out_json := out_json || jsonb_build_object(
      'score', rec.score, 'percent', rec.percent, 'breakdown', rec.breakdown);
  end if;

  return out_json;
end $$;

-- ---------- who may call what -----------------------------------------------

revoke all on function public.get_settings()                        from public;
revoke all on function public.get_paper()                           from public;
revoke all on function public.register_applicant(jsonb)             from public;
revoke all on function public.submit_test(text, jsonb, boolean)     from public;
revoke all on function public.get_status(text, text)                from public;

grant execute on function public.get_settings()                     to anon, authenticated;
grant execute on function public.get_paper()                        to anon, authenticated;
grant execute on function public.register_applicant(jsonb)          to anon, authenticated;
grant execute on function public.submit_test(text, jsonb, boolean)  to anon, authenticated;
grant execute on function public.get_status(text, text)             to anon, authenticated;
