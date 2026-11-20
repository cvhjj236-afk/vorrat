-- 1) Neue Kategorie "Süßes & Snacks" für HOFER/Lidl-Angebote
alter table public.vorrat_hofer_offers drop constraint if exists vorrat_hofer_offers_category_check;
alter table public.vorrat_hofer_offers add constraint vorrat_hofer_offers_category_check check(category in ('Obst','Gemüse','Fleisch & Wurst','Fisch & Meeresfrüchte','Milchprodukte & Eier','Brot & Backwaren','Reis, Nudeln & Trockenwaren','Konserven, Gläser & Saucen','Tiefkühlprodukte','Getränke','Süßes & Snacks'));
alter table public.vorrat_lidl_offers drop constraint if exists vorrat_lidl_offers_category_check;
alter table public.vorrat_lidl_offers add constraint vorrat_lidl_offers_category_check check(category in ('Obst','Gemüse','Fleisch & Wurst','Fisch & Meeresfrüchte','Milchprodukte & Eier','Brot & Backwaren','Reis, Nudeln & Trockenwaren','Konserven, Gläser & Saucen','Tiefkühlprodukte','Getränke','Süßes & Snacks'));

-- 2) PENNY-Import: Angebote kommen strukturiert von penny.at (kein OCR/Gemini). Ein Lauf = ein Schritt.
create table public.vorrat_penny_settings (
  id boolean primary key default true check (id),
  scheduled_enabled boolean not null default true,
  start_requested boolean not null default false,
  last_run_id uuid
);
insert into public.vorrat_penny_settings(id) values(true);

create table public.vorrat_penny_runs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  trigger_source text not null check(trigger_source in ('manual','scheduled')),
  status text not null default 'queued' check(status in ('queued','running','ready','skipped','failed')),
  fingerprint text,
  weeks jsonb not null default '[]',
  next_attempt_at timestamptz not null default now(),
  attempts integer not null default 0,
  lease_id uuid,
  lease_until timestamptz,
  error text,
  accepted_count integer not null default 0,
  review_count integer not null default 0,
  review jsonb not null default '[]'
);
create unique index vorrat_penny_one_active on public.vorrat_penny_runs ((true)) where status in ('queued','running');
create index vorrat_penny_runs_fingerprint on public.vorrat_penny_runs(fingerprint) where status='ready';

create table public.vorrat_penny_dispatch (
  run_id uuid primary key references public.vorrat_penny_runs(id),
  token text not null,
  expires_at timestamptz not null,
  used boolean not null default false
);

create table public.vorrat_penny_offers (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.vorrat_penny_runs(id),
  product_key text not null,
  name text not null,
  brand text,
  category text not null check(category in ('Obst','Gemüse','Fleisch & Wurst','Fisch & Meeresfrüchte','Milchprodukte & Eier','Brot & Backwaren','Reis, Nudeln & Trockenwaren','Konserven, Gläser & Saucen','Tiefkühlprodukte','Getränke','Süßes & Snacks')),
  price numeric not null check(price > 0 and price < 10000),
  quantity text,
  unit_price text,
  conditions text,
  valid_from date not null,
  valid_to date not null,
  page integer,
  source_url text not null,
  test_mode boolean not null default false,
  unique(run_id,product_key),
  check(valid_to >= valid_from and valid_to <= valid_from + 90)
);
create index vorrat_penny_offers_dates on public.vorrat_penny_offers(valid_to,valid_from);

alter table public.vorrat_penny_settings enable row level security;
alter table public.vorrat_penny_runs enable row level security;
alter table public.vorrat_penny_dispatch enable row level security;
alter table public.vorrat_penny_offers enable row level security;
revoke all on public.vorrat_penny_settings,public.vorrat_penny_runs,public.vorrat_penny_dispatch,public.vorrat_penny_offers from anon,authenticated;
grant all on public.vorrat_penny_settings,public.vorrat_penny_runs,public.vorrat_penny_dispatch,public.vorrat_penny_offers to service_role;

create function public.vorrat_penny_dispatch_run(p_run_id uuid) returns bigint
language plpgsql set search_path = '' as $$
declare v_token text; v_request bigint;
begin
  if not exists(select 1 from public.vorrat_penny_runs where id=p_run_id and status in ('queued','running') and next_attempt_at<=now() and (lease_until is null or lease_until<now())) then return null; end if;
  v_token := encode(extensions.gen_random_bytes(32),'hex');
  insert into public.vorrat_penny_dispatch(run_id,token,expires_at,used)
    values(p_run_id,v_token,now()+interval '5 minutes',false)
    on conflict(run_id) do update set token=excluded.token,expires_at=excluded.expires_at,used=false;
  select net.http_post(
    url:='https://wpxoddfaczbhxnmfidoj.supabase.co/functions/v1/vorrat-penny-import',
    headers:=jsonb_build_object('Content-Type','application/json'),
    body:=jsonb_build_object('run_id',p_run_id,'token',v_token),
    timeout_milliseconds:=5000) into v_request;
  return v_request;
end $$;

create function public.vorrat_penny_start(p_source text default 'manual') returns uuid
language plpgsql set search_path = '' as $$
declare v_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext('vorrat_penny_start'));
  select id into v_id from public.vorrat_penny_runs where status in ('queued','running') limit 1;
  if v_id is not null then return v_id; end if;
  insert into public.vorrat_penny_runs(trigger_source) values(p_source) returning id into v_id;
  update public.vorrat_penny_settings set last_run_id=v_id where id;
  perform public.vorrat_penny_dispatch_run(v_id);
  return v_id;
end $$;

create function public.vorrat_penny_settings_trigger() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.start_requested then
    update public.vorrat_penny_settings set start_requested=false where id=new.id;
    perform public.vorrat_penny_start('manual');
  end if;
  return new;
end $$;
create trigger vorrat_penny_manual_start after update on public.vorrat_penny_settings
for each row when(new.start_requested) execute function public.vorrat_penny_settings_trigger();

create function public.vorrat_penny_claim(p_run_id uuid,p_token text) returns jsonb
language plpgsql set search_path = '' as $$
declare v_run public.vorrat_penny_runs; v_lease uuid := gen_random_uuid();
begin
  select * into v_run from public.vorrat_penny_runs where id=p_run_id for update;
  if not found or v_run.status not in ('queued','running') or v_run.next_attempt_at>now() or v_run.lease_until>now() then return null; end if;
  update public.vorrat_penny_dispatch set used=true where run_id=p_run_id and token=p_token and not used and expires_at>now();
  if not found then return null; end if;
  if v_run.attempts>=3 then
    update public.vorrat_penny_runs set status='failed',finished_at=now(),error='Drei erfolglose Versuche.' where id=p_run_id;
    return null;
  end if;
  update public.vorrat_penny_runs set status='running',lease_id=v_lease,lease_until=now()+interval '4 minutes',attempts=attempts+1
    where id=p_run_id returning * into v_run;
  return to_jsonb(v_run);
end $$;

create function public.vorrat_penny_finish(p_run_id uuid,p_lease uuid,p_data jsonb) returns boolean
language plpgsql set search_path = '' as $$
declare v_run public.vorrat_penny_runs; v_offer jsonb;
begin
  select * into v_run from public.vorrat_penny_runs where id=p_run_id for update;
  if not found or v_run.lease_id is distinct from p_lease or v_run.status<>'running' then return false; end if;
  if p_data ? 'error' then
    update public.vorrat_penny_runs set
      status=case when coalesce((p_data->>'retry')::boolean,false) and attempts<3 then 'queued' else 'failed' end,
      error=p_data->>'error',lease_id=null,lease_until=null,
      next_attempt_at=now()+interval '2 minutes',
      finished_at=case when coalesce((p_data->>'retry')::boolean,false) and attempts<3 then null else now() end
      where id=p_run_id;
    return true;
  end if;
  update public.vorrat_penny_runs set fingerprint=p_data->>'fingerprint',weeks=coalesce(p_data->'weeks','[]'),review=coalesce(p_data->'review','[]'),
    review_count=jsonb_array_length(coalesce(p_data->'review','[]')) where id=p_run_id;
  if exists(select 1 from public.vorrat_penny_runs where id<>p_run_id and fingerprint=p_data->>'fingerprint' and status='ready') then
    update public.vorrat_penny_runs set status='skipped',finished_at=now(),error=null,lease_id=null,lease_until=null where id=p_run_id;
    return true;
  end if;
  for v_offer in select value from jsonb_array_elements(p_data->'offers') loop
    insert into public.vorrat_penny_offers(run_id,product_key,name,brand,category,price,quantity,unit_price,conditions,valid_from,valid_to,source_url)
      values(p_run_id,v_offer->>'product_key',v_offer->>'name',v_offer->>'brand',v_offer->>'category',(v_offer->>'price')::numeric,
        v_offer->>'quantity',v_offer->>'unit_price',v_offer->>'conditions',(v_offer->>'valid_from')::date,(v_offer->>'valid_to')::date,v_offer->>'source_url')
      on conflict(run_id,product_key) do nothing;
  end loop;
  update public.vorrat_penny_runs set status='ready',finished_at=now(),error=null,lease_id=null,lease_until=null,
    accepted_count=(select count(*) from public.vorrat_penny_offers where run_id=p_run_id) where id=p_run_id;
  return true;
end $$;

create function public.vorrat_penny_tick() returns void language plpgsql set search_path = '' as $$
declare v_id uuid;
begin
  for v_id in select id from public.vorrat_penny_runs where status in ('queued','running') and next_attempt_at<=now() and (lease_until is null or lease_until<now()) loop
    perform public.vorrat_penny_dispatch_run(v_id);
  end loop;
end $$;

-- Katalog: Angebote des jüngsten abgeschlossenen Laufs (enthält aktuelle + nächste Woche), nur nicht abgelaufene.
create function public.vorrat_penny_catalog() returns setof public.vorrat_penny_offers
language sql security definer set search_path = '' stable as $$
  select o.* from public.vorrat_penny_offers o
  where auth.uid() is not null and public.vorrat_my_household() is not null
    and o.valid_to >= (now() at time zone 'Europe/Vienna')::date
    and o.run_id=(select r.id from public.vorrat_penny_runs r where r.status='ready' order by r.finished_at desc limit 1)
  order by o.valid_from,o.category,o.name;
$$;

revoke all on function public.vorrat_penny_dispatch_run(uuid),public.vorrat_penny_start(text),public.vorrat_penny_settings_trigger(),public.vorrat_penny_claim(uuid,text),public.vorrat_penny_finish(uuid,uuid,jsonb),public.vorrat_penny_tick(),public.vorrat_penny_catalog() from public,anon,authenticated;
grant execute on function public.vorrat_penny_dispatch_run(uuid),public.vorrat_penny_start(text),public.vorrat_penny_claim(uuid,text),public.vorrat_penny_finish(uuid,uuid,jsonb) to service_role;
grant execute on function public.vorrat_penny_catalog() to authenticated;

select cron.schedule('vorrat-penny-worker','15 seconds','select public.vorrat_penny_tick();');

-- 3) Wochenplan: PENNY als dritter Schritt nach HOFER und Lidl (Do 0:00-5:59 Wien, max. 8 Fehlversuche pro Quelle/Nacht)
create or replace function public.vorrat_flyers_weekly() returns text
language plpgsql set search_path = '' as $$
declare
  v_now timestamp := now() at time zone 'Europe/Vienna';
  v_day timestamptz := date_trunc('day', now() at time zone 'Europe/Vienna') at time zone 'Europe/Vienna';
  v_h_on boolean := exists(select 1 from public.vorrat_hofer_settings where scheduled_enabled);
  v_h_ok boolean := exists(select 1 from public.vorrat_hofer_runs where trigger_source='scheduled' and status in ('ready','skipped') and created_at >= v_day);
  v_h_fails int := (select count(*) from public.vorrat_hofer_runs where trigger_source='scheduled' and status='failed' and created_at >= v_day);
  v_h_done boolean;
  v_l_on boolean := exists(select 1 from public.vorrat_lidl_settings where scheduled_enabled);
  v_l_ok boolean := exists(select 1 from public.vorrat_lidl_runs where trigger_source='scheduled' and status in ('ready','skipped') and created_at >= v_day);
  v_l_fails int := (select count(*) from public.vorrat_lidl_runs where trigger_source='scheduled' and status='failed' and created_at >= v_day);
  v_l_done boolean;
  v_p_on boolean := exists(select 1 from public.vorrat_penny_settings where scheduled_enabled);
  v_p_ok boolean := exists(select 1 from public.vorrat_penny_runs where trigger_source='scheduled' and status in ('ready','skipped') and created_at >= v_day);
  v_p_fails int := (select count(*) from public.vorrat_penny_runs where trigger_source='scheduled' and status='failed' and created_at >= v_day);
begin
  if extract(isodow from v_now) <> 4 or extract(hour from v_now) > 5 then return 'ausserhalb'; end if;
  if exists(select 1 from public.vorrat_hofer_runs where status in ('queued','running'))
     or exists(select 1 from public.vorrat_lidl_runs where status in ('queued','running'))
     or exists(select 1 from public.vorrat_penny_runs where status in ('queued','running')) then return 'laeuft'; end if;
  v_h_done := v_h_ok or v_h_fails >= 8 or not v_h_on;
  v_l_done := v_l_ok or v_l_fails >= 8 or not v_l_on;
  if v_h_on and not v_h_ok and v_h_fails < 8 then
    perform public.vorrat_hofer_start('scheduled'); return 'hofer';
  end if;
  if v_l_on and v_h_done and not v_l_ok and v_l_fails < 8 then
    perform public.vorrat_lidl_start('scheduled'); return 'lidl';
  end if;
  if v_p_on and v_h_done and v_l_done and not v_p_ok and v_p_fails < 8 then
    perform public.vorrat_penny_start('scheduled'); return 'penny';
  end if;
  return 'fertig';
end $$;

-- 4) Aufräumen: Penny-Angebote nach Ablauf bzw. von überholten Läufen löschen
create or replace function public.vorrat_flyers_cleanup() returns text
language plpgsql security definer set search_path to '' as $$
declare
  v_today date := (now() at time zone 'Europe/Vienna')::date;
  v_ho int; v_li int; v_hp int; v_lp int; v_pe int;
begin
  delete from public.vorrat_hofer_offers o
   where o.valid_to < v_today - 7
      or (o.test_mode and exists (select 1 from public.vorrat_hofer_runs r where r.id=o.run_id and r.created_at < now() - interval '7 days'));
  get diagnostics v_ho = row_count;
  delete from public.vorrat_lidl_offers o
   where o.valid_to < v_today - 7
      or (o.test_mode and exists (select 1 from public.vorrat_lidl_runs r where r.id=o.run_id and r.created_at < now() - interval '7 days'));
  get diagnostics v_li = row_count;
  delete from public.vorrat_penny_offers o
   where o.valid_to < v_today - 7
      or o.run_id is distinct from (select r.id from public.vorrat_penny_runs r where r.status='ready' order by r.finished_at desc limit 1);
  get diagnostics v_pe = row_count;
  delete from public.vorrat_hofer_pages p using public.vorrat_hofer_runs r
   where r.id=p.run_id and r.created_at < now() - interval '30 days' and r.status not in ('queued','running');
  get diagnostics v_hp = row_count;
  delete from public.vorrat_lidl_pages p using public.vorrat_lidl_runs r
   where r.id=p.run_id and r.created_at < now() - interval '30 days' and r.status not in ('queued','running');
  get diagnostics v_lp = row_count;
  return format('hofer_offers=%s lidl_offers=%s penny_offers=%s hofer_pages=%s lidl_pages=%s', v_ho, v_li, v_pe, v_hp, v_lp);
end $$;
revoke all on function public.vorrat_flyers_cleanup() from public, anon, authenticated;
