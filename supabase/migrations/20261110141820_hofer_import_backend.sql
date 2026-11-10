-- Backend controls are restricted to project administrators/service_role.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create table public.vorrat_hofer_settings (
  id boolean primary key default true check (id),
  test_mode boolean not null default true,
  start_requested boolean not null default false,
  scheduled_enabled boolean not null default true,
  source_url text,
  last_run_id uuid,
  note text not null default 'Testmodus: erste 5 Seiten. Manueller Start: start_requested auf true setzen und speichern. Mittwoch 15 Uhr Europe/Vienna.',
  check (source_url is null or source_url ~ '^https://katalog[.]hofer[.]at/flipbook_kw[0-9]{2}_[0-9]{2}_0/?$')
);
insert into public.vorrat_hofer_settings(id) values(true);

create table public.vorrat_hofer_runs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  trigger_source text not null check(trigger_source in ('manual','scheduled')),
  test_mode boolean not null,
  status text not null default 'queued' check(status in ('queued','running','test_complete','ready','skipped','failed')),
  source_url text,
  edition text,
  source_description text,
  fingerprint text,
  pages jsonb not null default '[]',
  total_pages integer,
  pages_done integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  attempts integer not null default 0,
  lease_id uuid,
  lease_until timestamptz,
  error text,
  model text,
  accepted_count integer not null default 0,
  review_count integer not null default 0,
  check (not test_mode or jsonb_array_length(pages) <= 5)
);
create unique index vorrat_hofer_one_active on public.vorrat_hofer_runs ((true)) where status in ('queued','running');
create index vorrat_hofer_runs_fingerprint on public.vorrat_hofer_runs(fingerprint,test_mode) where status in ('ready','test_complete');

create table public.vorrat_hofer_pages (
  run_id uuid not null references public.vorrat_hofer_runs(id),
  page integer not null,
  image_sha256 text not null,
  offers jsonb not null,
  review jsonb not null,
  usage jsonb not null default '{}',
  primary key(run_id,page)
);
create table public.vorrat_hofer_dispatch (
  run_id uuid primary key references public.vorrat_hofer_runs(id),
  token text not null,
  expires_at timestamptz not null,
  used boolean not null default false
);
create table public.vorrat_hofer_offers (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.vorrat_hofer_runs(id),
  product_key text not null,
  name text not null,
  brand text,
  category text not null check(category in ('Obst','Gemüse','Fleisch & Wurst','Fisch & Meeresfrüchte','Milchprodukte & Eier','Brot & Backwaren','Reis, Nudeln & Trockenwaren','Konserven, Gläser & Saucen','Tiefkühlprodukte','Getränke')),
  price numeric not null check(price > 0 and price < 10000),
  quantity text,
  unit_price text,
  conditions text,
  valid_from date not null,
  valid_to date not null,
  page integer not null check(page > 0),
  source_url text not null,
  test_mode boolean not null,
  unique(run_id,product_key),
  check(valid_to >= valid_from and valid_to <= valid_from + 60)
);
create index vorrat_hofer_offers_dates on public.vorrat_hofer_offers(valid_to,valid_from) where not test_mode;

alter table public.vorrat_hofer_settings enable row level security;
alter table public.vorrat_hofer_runs enable row level security;
alter table public.vorrat_hofer_pages enable row level security;
alter table public.vorrat_hofer_dispatch enable row level security;
alter table public.vorrat_hofer_offers enable row level security;
revoke all on public.vorrat_hofer_settings,public.vorrat_hofer_runs,public.vorrat_hofer_pages,public.vorrat_hofer_dispatch,public.vorrat_hofer_offers from anon,authenticated;
grant all on public.vorrat_hofer_settings,public.vorrat_hofer_runs,public.vorrat_hofer_pages,public.vorrat_hofer_dispatch,public.vorrat_hofer_offers to service_role;
-- The shared catalog is readable by household members through a restricted RPC.

create function public.vorrat_hofer_dispatch_run(p_run_id uuid) returns bigint
language plpgsql set search_path = '' as $$
declare v_token text; v_request bigint;
begin
  if not exists(select 1 from public.vorrat_hofer_runs where id=p_run_id and status in ('queued','running') and next_attempt_at<=now() and (lease_until is null or lease_until<now())) then return null; end if;
  v_token := encode(extensions.gen_random_bytes(32),'hex');
  insert into public.vorrat_hofer_dispatch(run_id,token,expires_at,used)
    values(p_run_id,v_token,now()+interval '5 minutes',false)
    on conflict(run_id) do update set token=excluded.token,expires_at=excluded.expires_at,used=false;
  select net.http_post(
    url:='https://wpxoddfaczbhxnmfidoj.supabase.co/functions/v1/vorrat-hofer-import',
    headers:=jsonb_build_object('Content-Type','application/json'),
    body:=jsonb_build_object('run_id',p_run_id,'token',v_token),
    timeout_milliseconds:=5000) into v_request;
  return v_request;
end $$;

create function public.vorrat_hofer_start(p_source text default 'manual') returns uuid
language plpgsql set search_path = '' as $$
declare v_id uuid; v_settings public.vorrat_hofer_settings;
begin
  perform pg_advisory_xact_lock(hashtext('vorrat_hofer_start'));
  select id into v_id from public.vorrat_hofer_runs where status in ('queued','running') limit 1;
  if v_id is not null then return v_id; end if;
  select * into strict v_settings from public.vorrat_hofer_settings where id;
  insert into public.vorrat_hofer_runs(trigger_source,test_mode,source_url)
    values(p_source,v_settings.test_mode,v_settings.source_url) returning id into v_id;
  update public.vorrat_hofer_settings set last_run_id=v_id where id;
  perform public.vorrat_hofer_dispatch_run(v_id);
  return v_id;
end $$;

create function public.vorrat_hofer_settings_trigger() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.start_requested then
    -- AFTER trigger sees the newly saved test_mode/source_url configuration.
    update public.vorrat_hofer_settings set start_requested=false where id=new.id;
    perform public.vorrat_hofer_start('manual');
  end if;
  return new;
end $$;
create trigger vorrat_hofer_manual_start after update on public.vorrat_hofer_settings
for each row when(new.start_requested) execute function public.vorrat_hofer_settings_trigger();

create function public.vorrat_hofer_claim(p_run_id uuid,p_token text) returns jsonb
language plpgsql set search_path = '' as $$
declare v_run public.vorrat_hofer_runs; v_lease uuid := gen_random_uuid();
begin
  select * into v_run from public.vorrat_hofer_runs where id=p_run_id for update;
  if not found or v_run.status not in ('queued','running') or v_run.next_attempt_at>now() or v_run.lease_until>now() then return null; end if;
  update public.vorrat_hofer_dispatch set used=true where run_id=p_run_id and token=p_token and not used and expires_at>now();
  if not found then return null; end if;
  if v_run.attempts>=3 then
    update public.vorrat_hofer_runs set status='failed',finished_at=now(),error='Drei erfolglose Versuche für denselben Verarbeitungsschritt.' where id=p_run_id;
    return null;
  end if;
  update public.vorrat_hofer_runs set status='running',lease_id=v_lease,lease_until=now()+interval '2 minutes',attempts=attempts+1
    where id=p_run_id returning * into v_run;
  return to_jsonb(v_run);
end $$;

create function public.vorrat_hofer_finish_step(p_run_id uuid,p_lease uuid,p_data jsonb) returns boolean
language plpgsql set search_path = '' as $$
declare v_run public.vorrat_hofer_runs; v_page jsonb; v_offer jsonb;
begin
  select * into v_run from public.vorrat_hofer_runs where id=p_run_id for update;
  if not found or v_run.lease_id is distinct from p_lease or v_run.status<>'running' then return false; end if;
  if p_data ? 'error' then
    update public.vorrat_hofer_runs set
      status=case when coalesce((p_data->>'retry')::boolean,false) and attempts<3 then 'queued' else 'failed' end,
      error=p_data->>'error',lease_id=null,lease_until=null,
      next_attempt_at=now()+interval '2 minutes',
      finished_at=case when coalesce((p_data->>'retry')::boolean,false) and attempts<3 then null else now() end
      where id=p_run_id;
    return true;
  end if;
  if p_data ? 'pages' then
    if v_run.test_mode and jsonb_array_length(p_data->'pages')>5 then raise exception 'Testmodus maximal fünf Seiten'; end if;
    update public.vorrat_hofer_runs set edition=p_data->>'edition',source_url=p_data->>'source_url',source_description=p_data->>'description',
      fingerprint=p_data->>'fingerprint',pages=p_data->'pages',total_pages=(p_data->>'total_pages')::integer,model=p_data->>'model'
      where id=p_run_id;
    if exists(select 1 from public.vorrat_hofer_runs where id<>p_run_id and fingerprint=p_data->>'fingerprint' and test_mode=v_run.test_mode and status in ('ready','test_complete')) then
      update public.vorrat_hofer_runs set status='skipped',finished_at=now(),lease_id=null,lease_until=null where id=p_run_id;
      return true;
    end if;
  else
    v_page := p_data->'page';
    if (v_page->>'number')::integer<>(v_run.pages->v_run.pages_done->>'number')::integer then raise exception 'Unerwartete Seite'; end if;
    insert into public.vorrat_hofer_pages(run_id,page,image_sha256,offers,review,usage)
      values(p_run_id,(v_page->>'number')::integer,v_page->>'image_sha256',v_page->'offers',v_page->'review',coalesce(v_page->'usage','{}'));
    update public.vorrat_hofer_runs set pages_done=pages_done+1 where id=p_run_id;
  end if;
  select * into v_run from public.vorrat_hofer_runs where id=p_run_id;
  if jsonb_array_length(v_run.pages)>0 and v_run.pages_done=jsonb_array_length(v_run.pages) then
    for v_offer in select value from public.vorrat_hofer_pages p cross join lateral jsonb_array_elements(p.offers) where p.run_id=p_run_id loop
      insert into public.vorrat_hofer_offers(run_id,product_key,name,brand,category,price,quantity,unit_price,conditions,valid_from,valid_to,page,source_url,test_mode)
        values(p_run_id,v_offer->>'product_key',v_offer->>'name',v_offer->>'brand',v_offer->>'category',(v_offer->>'price')::numeric,
          v_offer->>'quantity',v_offer->>'unit_price',v_offer->>'conditions',(v_offer->>'valid_from')::date,(v_offer->>'valid_to')::date,
          (v_offer->>'page')::integer,v_run.source_url,v_run.test_mode)
        on conflict(run_id,product_key) do nothing;
    end loop;
    update public.vorrat_hofer_runs set status=case when test_mode then 'test_complete' else 'ready' end,finished_at=now(),error=null,
      accepted_count=(select count(*) from public.vorrat_hofer_offers where run_id=p_run_id),
      review_count=(select coalesce(sum(jsonb_array_length(review)),0) from public.vorrat_hofer_pages where run_id=p_run_id),
      lease_id=null,lease_until=null where id=p_run_id;
  else
    update public.vorrat_hofer_runs set status='queued',attempts=0,error=null,lease_id=null,lease_until=null,next_attempt_at=now()+interval '15 seconds' where id=p_run_id;
  end if;
  return true;
end $$;

create function public.vorrat_hofer_tick() returns void language plpgsql set search_path = '' as $$
declare v_id uuid;
begin
  for v_id in select id from public.vorrat_hofer_runs where status in ('queued','running') and next_attempt_at<=now() and (lease_until is null or lease_until<now()) loop
    perform public.vorrat_hofer_dispatch_run(v_id);
  end loop;
end $$;

create function public.vorrat_hofer_weekly() returns uuid language plpgsql set search_path = '' as $$
begin
  if extract(isodow from now() at time zone 'Europe/Vienna')=3 and extract(hour from now() at time zone 'Europe/Vienna')=15
    and exists(select 1 from public.vorrat_hofer_settings where scheduled_enabled)
    and not exists(select 1 from public.vorrat_hofer_runs where trigger_source='scheduled' and created_at >= date_trunc('day',now() at time zone 'Europe/Vienna') at time zone 'Europe/Vienna') then
    return public.vorrat_hofer_start('scheduled');
  end if;
  return null;
end $$;

-- Restricted shared read, household membership is checked with the existing helper.
create function public.vorrat_hofer_catalog() returns setof public.vorrat_hofer_offers
language sql security definer set search_path = '' stable as $$
  select o.* from public.vorrat_hofer_offers o
  join public.vorrat_hofer_runs r on r.id=o.run_id
  where auth.uid() is not null and public.vorrat_my_household() is not null
    and not o.test_mode and r.status='ready' and o.valid_to >= current_date
    and not exists(select 1 from public.vorrat_hofer_runs newer where newer.edition=r.edition and newer.status='ready' and newer.finished_at>r.finished_at)
  order by o.valid_from,o.category,o.name;
$$;

revoke all on function public.vorrat_hofer_dispatch_run(uuid),public.vorrat_hofer_start(text),public.vorrat_hofer_settings_trigger(),public.vorrat_hofer_claim(uuid,text),public.vorrat_hofer_finish_step(uuid,uuid,jsonb),public.vorrat_hofer_tick(),public.vorrat_hofer_weekly(),public.vorrat_hofer_catalog() from public,anon,authenticated;
grant execute on function public.vorrat_hofer_dispatch_run(uuid),public.vorrat_hofer_start(text),public.vorrat_hofer_claim(uuid,text),public.vorrat_hofer_finish_step(uuid,uuid,jsonb) to service_role;
grant execute on function public.vorrat_hofer_catalog() to authenticated;

select cron.schedule('vorrat-hofer-weekly','0 * * * 3','select public.vorrat_hofer_weekly();');
select cron.schedule('vorrat-hofer-worker','15 seconds','select public.vorrat_hofer_tick();');
