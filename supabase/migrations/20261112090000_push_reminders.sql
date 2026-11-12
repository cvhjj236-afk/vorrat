-- Push-Erinnerungen: Haushaltsmitglieder schicken einander Erinnerungen (Text + Artikel / Einkaufsliste) zu einer eingestellten Zeit.
-- Betrifft nur neue vorrat_push_*-Objekte. Bestehende Tabellen werden nur gelesen (vorrat_members, vorrat_items).

create table public.vorrat_push_subs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  household_id uuid not null default public.vorrat_my_household() references public.vorrat_households(id) on delete cascade,
  endpoint text not null unique check (endpoint ~ '^https://'),
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table public.vorrat_push_subs enable row level security;
create policy vorrat_push_subs_own on public.vorrat_push_subs for select to authenticated using (user_id = auth.uid());
create policy vorrat_push_subs_del on public.vorrat_push_subs for delete to authenticated using (user_id = auth.uid());
grant select, delete on public.vorrat_push_subs to authenticated;

create table public.vorrat_push_reminders (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.vorrat_my_household() references public.vorrat_households(id) on delete cascade,
  created_by uuid not null default auth.uid(),
  recipient_id uuid not null,
  title text not null check (char_length(btrim(title)) between 1 and 80),
  body text not null default '' check (char_length(body) <= 500),
  item_names text[] not null default '{}' check (cardinality(item_names) <= 30),
  include_list boolean not null default false,
  repeat text not null check (repeat in ('once','daily')),
  send_at timestamptz not null,
  active boolean not null default true,
  last_sent_at timestamptz,
  last_status text,
  created_at timestamptz not null default now()
);
create index vorrat_push_reminders_due on public.vorrat_push_reminders(send_at) where active;
alter table public.vorrat_push_reminders enable row level security;
create policy vorrat_push_reminders_hh on public.vorrat_push_reminders for select to authenticated
  using (household_id = public.vorrat_my_household());
create policy vorrat_push_reminders_del on public.vorrat_push_reminders for delete to authenticated
  using (household_id = public.vorrat_my_household());
grant select, delete on public.vorrat_push_reminders to authenticated;

create table public.vorrat_push_dispatch (
  token text primary key,
  expires_at timestamptz not null,
  used boolean not null default false
);
alter table public.vorrat_push_dispatch enable row level security;
revoke all on public.vorrat_push_dispatch from anon, authenticated;
grant all on public.vorrat_push_dispatch to service_role;

-- Mitglieder meines Haushalts mit Anzahl der Geräte, auf die gepusht werden kann.
create function public.vorrat_push_recipients() returns table(user_id uuid, label text, me boolean, devices integer)
language sql stable security definer set search_path = '' as $$
  select m.user_id, split_part(m.email,'@',1), m.user_id = auth.uid(),
         (select count(*)::int from public.vorrat_push_subs s where s.user_id = m.user_id)
  from public.vorrat_members m
  where m.household_id = public.vorrat_my_household() and auth.uid() is not null
  order by (m.user_id = auth.uid()) desc, m.joined_at;
$$;

-- Gerät dieses Nutzers registrieren (ersetzt ein evtl. vorhandenes Abo desselben Endpoints).
create function public.vorrat_push_save_sub(p_endpoint text, p_p256dh text, p_auth text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.vorrat_my_household() is null then return false; end if;
  insert into public.vorrat_push_subs(user_id, household_id, endpoint, p256dh, auth)
    values (auth.uid(), public.vorrat_my_household(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = auth.uid(), household_id = public.vorrat_my_household(),
    p256dh = excluded.p256dh, auth = excluded.auth;
  return true;
end $$;

-- Erinnerung anlegen. p_time ist Wiener Ortszeit; p_date nur für 'once'. Bei 'daily' ist es der nächste Zeitpunkt dieser Uhrzeit.
create function public.vorrat_push_save_reminder(
  p_recipient uuid, p_title text, p_body text, p_items text[], p_include_list boolean,
  p_repeat text, p_date date, p_time time
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_hh uuid := public.vorrat_my_household(); v_at timestamptz; v_id uuid;
begin
  if auth.uid() is null or v_hh is null then raise exception 'not allowed'; end if;
  if not exists(select 1 from public.vorrat_members where user_id = p_recipient and household_id = v_hh) then
    raise exception 'recipient not in household';
  end if;
  if p_repeat not in ('once','daily') then raise exception 'bad repeat'; end if;
  if p_repeat = 'once' then
    v_at := ((p_date + p_time) at time zone 'Europe/Vienna');
  else
    v_at := (((now() at time zone 'Europe/Vienna')::date + p_time) at time zone 'Europe/Vienna');
    if v_at <= now() then v_at := ((((now() at time zone 'Europe/Vienna')::date + 1) + p_time) at time zone 'Europe/Vienna'); end if;
  end if;
  if p_repeat = 'once' and v_at <= now() then raise exception 'in the past'; end if;
  insert into public.vorrat_push_reminders(household_id, created_by, recipient_id, title, body, item_names, include_list, repeat, send_at)
    values (v_hh, auth.uid(), p_recipient, left(btrim(p_title),80), left(coalesce(p_body,''),500),
            coalesce(p_items,'{}'), coalesce(p_include_list,false), p_repeat, v_at)
    returning id into v_id;
  return v_id;
end $$;

grant execute on function public.vorrat_push_recipients() to authenticated;
grant execute on function public.vorrat_push_save_sub(text,text,text) to authenticated;
grant execute on function public.vorrat_push_save_reminder(uuid,text,text,text[],boolean,text,date,time) to authenticated;
revoke execute on function public.vorrat_push_recipients(), public.vorrat_push_save_sub(text,text,text),
  public.vorrat_push_save_reminder(uuid,text,text,text[],boolean,text,date,time) from anon, public;

-- Fällige Erinnerungen abholen (nur Edge Function, per Einmal-Token). Setzt sie sofort weiter.
create function public.vorrat_push_claim(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; v_out jsonb := '[]'; v_body text; v_list text; v_subs jsonb; v_next timestamptz;
begin
  update public.vorrat_push_dispatch set used = true where token = p_token and not used and expires_at > now();
  if not found then return null; end if;
  for r in select * from public.vorrat_push_reminders where active and send_at <= now() order by send_at limit 50 for update skip locked loop
    v_body := r.body;
    if cardinality(r.item_names) > 0 then
      v_body := btrim(v_body || E'\n' || array_to_string(r.item_names, ', '));
    end if;
    if r.include_list then
      select string_agg(name, ', ' order by name) into v_list
        from (select name from public.vorrat_items where household_id = r.household_id and status = 'list' order by name limit 25) x;
      if v_list is not null then v_body := btrim(v_body || E'\nEinkaufsliste: ' || v_list); end if;
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)), '[]')
      into v_subs from public.vorrat_push_subs where user_id = r.recipient_id;
    if r.repeat = 'once' then
      update public.vorrat_push_reminders set active = false, last_sent_at = now(),
        last_status = case when jsonb_array_length(v_subs) = 0 then 'kein Gerät' else 'gesendet' end where id = r.id;
    else
      v_next := r.send_at;
      while v_next <= now() loop v_next := ((v_next at time zone 'Europe/Vienna') + interval '1 day') at time zone 'Europe/Vienna'; end loop;
      update public.vorrat_push_reminders set send_at = v_next, last_sent_at = now(),
        last_status = case when jsonb_array_length(v_subs) = 0 then 'kein Gerät' else 'gesendet' end where id = r.id;
    end if;
    v_out := v_out || jsonb_build_object('title', r.title, 'body', left(v_body, 600), 'subs', v_subs);
  end loop;
  return v_out;
end $$;

create function public.vorrat_push_drop(p_endpoint text) returns void
language sql security definer set search_path = '' as $$
  delete from public.vorrat_push_subs where endpoint = p_endpoint;
$$;
revoke all on function public.vorrat_push_claim(text), public.vorrat_push_drop(text) from anon, authenticated, public;
grant execute on function public.vorrat_push_claim(text), public.vorrat_push_drop(text) to service_role;

-- Jede Minute: gibt es etwas Fälliges? Dann Edge Function mit Einmal-Token anstoßen.
create function public.vorrat_push_tick() returns void
language plpgsql set search_path = '' as $$
declare v_token text;
begin
  if not exists(select 1 from public.vorrat_push_reminders where active and send_at <= now()) then return; end if;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.vorrat_push_dispatch(token, expires_at) values (v_token, now() + interval '2 minutes');
  delete from public.vorrat_push_dispatch where expires_at < now() - interval '1 day';
  perform net.http_post(
    url := 'https://wpxoddfaczbhxnmfidoj.supabase.co/functions/v1/vorrat-push',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('token', v_token),
    timeout_milliseconds := 5000);
end $$;
revoke all on function public.vorrat_push_tick() from anon, authenticated, public;

select cron.schedule('vorrat-push-tick', '* * * * *', $$select public.vorrat_push_tick()$$);
