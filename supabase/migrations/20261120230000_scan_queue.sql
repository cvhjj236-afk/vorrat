-- Foto-Warteschlange: Kassabon-/Einkaufszettel-Fotos, die Gemini gerade nicht auswerten konnte,
-- werden im Backend zwischengespeichert und alle 5 Minuten erneut versucht (max. 24 Versuche = 2 h).
-- Nach Erfolg wird das Foto sofort gelöscht, das Ergebnis liegt bis zur Übernahme in der App (max. 7 Tage).
create table public.vorrat_scan_jobs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.vorrat_my_household() references public.vorrat_households(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  mode text not null check (mode in ('receipt','list')),
  image text,                      -- JPEG als Base64, wird nach Erfolg/Endfehler auf NULL gesetzt
  status text not null default 'queued' check (status in ('queued','running','done','failed')),
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now() + interval '5 minutes',
  lease_id uuid, lease_until timestamptz,
  last_error text, result jsonb,
  created_at timestamptz not null default now(), finished_at timestamptz
);
create index vorrat_scan_jobs_due on public.vorrat_scan_jobs(next_attempt_at) where status in ('queued','running');
create table public.vorrat_scan_dispatch (job_id uuid primary key references public.vorrat_scan_jobs(id) on delete cascade, token text not null, expires_at timestamptz not null, used boolean not null default false);

alter table public.vorrat_scan_jobs enable row level security;
alter table public.vorrat_scan_dispatch enable row level security;
create policy scan_jobs_select on public.vorrat_scan_jobs for select to authenticated using (household_id = public.vorrat_my_household());
revoke all on public.vorrat_scan_jobs, public.vorrat_scan_dispatch from public, anon, authenticated;
-- Das Foto selbst ist für Clients nie lesbar.
grant select (id, mode, status, attempts, next_attempt_at, last_error, result, created_at, finished_at) on public.vorrat_scan_jobs to authenticated;
grant all on public.vorrat_scan_jobs, public.vorrat_scan_dispatch to service_role;

create function public.vorrat_scan_enqueue(p_image text, p_mode text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_email text;
begin
  if auth.uid() is null or public.vorrat_my_household() is null then raise exception 'not_member'; end if;
  select lower(email) into v_email from auth.users where id = auth.uid() and email_confirmed_at is not null;
  if v_email is null or not exists(select 1 from public.ai_allowlist where lower(email) = v_email) then raise exception 'ai_not_allowed'; end if;
  if p_mode not in ('receipt','list') then raise exception 'bad_mode'; end if;
  if p_image is null or length(p_image) < 100 or length(p_image) > 3000000 or p_image !~ '^[A-Za-z0-9+/=]+$' then raise exception 'bad_image'; end if;
  if (select count(*) from public.vorrat_scan_jobs where household_id = public.vorrat_my_household() and status in ('queued','running')) >= 5 then raise exception 'queue_full'; end if;
  insert into public.vorrat_scan_jobs(mode, image) values (p_mode, p_image) returning id into v_id;
  return v_id;
end $$;

-- Ergebnis übernommen bzw. verworfen -> Auftrag samt Daten löschen.
create function public.vorrat_scan_ack(p_id uuid) returns void
language sql security definer set search_path = '' as $$
  delete from public.vorrat_scan_jobs where id = p_id and household_id = public.vorrat_my_household();
$$;

create function public.vorrat_scan_dispatch_job(p_id uuid) returns bigint
language plpgsql set search_path = '' as $$
declare v_token text; v_request bigint;
begin
  v_token := encode(extensions.gen_random_bytes(32),'hex');
  insert into public.vorrat_scan_dispatch(job_id, token, expires_at, used) values (p_id, v_token, now() + interval '5 minutes', false)
    on conflict(job_id) do update set token = excluded.token, expires_at = excluded.expires_at, used = false;
  select net.http_post(url := 'https://wpxoddfaczbhxnmfidoj.supabase.co/functions/v1/vorrat-scan-worker',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object('job_id', p_id, 'token', v_token), timeout_milliseconds := 5000) into v_request;
  return v_request;
end $$;

create function public.vorrat_scan_claim(p_id uuid, p_token text) returns jsonb
language plpgsql set search_path = '' as $$
declare v public.vorrat_scan_jobs; v_lease uuid := gen_random_uuid();
begin
  select * into v from public.vorrat_scan_jobs where id = p_id for update;
  if not found or v.status not in ('queued','running') or v.next_attempt_at > now() or v.lease_until > now() then return null; end if;
  update public.vorrat_scan_dispatch set used = true where job_id = p_id and token = p_token and not used and expires_at > now();
  if not found then return null; end if;
  if v.attempts >= 24 or v.image is null then
    update public.vorrat_scan_jobs set status='failed', image=null, finished_at=now(), lease_id=null, lease_until=null,
      last_error = coalesce(last_error,'Auswertung nach mehreren Versuchen nicht möglich.') where id = p_id;
    return null;
  end if;
  update public.vorrat_scan_jobs set status='running', lease_id=v_lease, lease_until=now()+interval '3 minutes', attempts=attempts+1
    where id = p_id returning * into v;
  return jsonb_build_object('id', v.id, 'mode', v.mode, 'image', v.image, 'lease_id', v.lease_id, 'attempts', v.attempts);
end $$;

-- p_data: {result:{...}} bei Erfolg, sonst {error:text, retry:bool}
create function public.vorrat_scan_finish(p_id uuid, p_lease uuid, p_data jsonb) returns boolean
language plpgsql set search_path = '' as $$
declare v public.vorrat_scan_jobs; v_retry boolean;
begin
  select * into v from public.vorrat_scan_jobs where id = p_id for update;
  if not found or v.lease_id is distinct from p_lease or v.status <> 'running' then return false; end if;
  if p_data ? 'result' then
    update public.vorrat_scan_jobs set status='done', result=p_data->'result', image=null, finished_at=now(), last_error=null, lease_id=null, lease_until=null where id = p_id;
    return true;
  end if;
  v_retry := coalesce((p_data->>'retry')::boolean, false) and v.attempts < 24;
  update public.vorrat_scan_jobs set
    status = case when v_retry then 'queued' else 'failed' end,
    image = case when v_retry then image else null end,
    finished_at = case when v_retry then null else now() end,
    next_attempt_at = now() + interval '5 minutes',
    last_error = left(coalesce(p_data->>'error','Unbekannter Fehler'), 300), lease_id=null, lease_until=null
    where id = p_id;
  return true;
end $$;

-- Jede Minute: fällige Aufträge anstoßen, hängende Leases freigeben, Altlasten aufräumen.
create function public.vorrat_scan_tick() returns void
language plpgsql set search_path = '' as $$
declare v_id uuid;
begin
  update public.vorrat_scan_jobs set status='queued', lease_id=null, lease_until=null where status='running' and lease_until < now();
  -- Notbremse: nichts bleibt länger als 3 h in der Warteschlange, Fotos werden dann gelöscht.
  update public.vorrat_scan_jobs set status='failed', image=null, finished_at=now(), last_error=coalesce(last_error,'Zeit abgelaufen.')
    where status in ('queued','running') and created_at < now() - interval '3 hours';
  update public.vorrat_scan_jobs set image=null where image is not null and status in ('done','failed');
  delete from public.vorrat_scan_jobs where (status='failed' and finished_at < now() - interval '3 days') or created_at < now() - interval '7 days';
  for v_id in select id from public.vorrat_scan_jobs where status='queued' and next_attempt_at <= now() order by next_attempt_at limit 5 loop
    perform public.vorrat_scan_dispatch_job(v_id);
  end loop;
end $$;

revoke all on function public.vorrat_scan_enqueue(text,text), public.vorrat_scan_ack(uuid), public.vorrat_scan_dispatch_job(uuid),
  public.vorrat_scan_claim(uuid,text), public.vorrat_scan_finish(uuid,uuid,jsonb), public.vorrat_scan_tick() from public, anon, authenticated;
grant execute on function public.vorrat_scan_enqueue(text,text), public.vorrat_scan_ack(uuid) to authenticated;
grant execute on function public.vorrat_scan_claim(uuid,text), public.vorrat_scan_finish(uuid,uuid,jsonb), public.vorrat_scan_dispatch_job(uuid), public.vorrat_scan_tick() to service_role;

select cron.schedule('vorrat-scan-worker', '* * * * *', 'select public.vorrat_scan_tick();');
