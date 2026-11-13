-- Lidl darf auch starten, wenn HOFER aufgegeben wurde (8 Fehlversuche) oder nicht automatisch laeuft.
create or replace function public.vorrat_flyers_weekly() returns text language plpgsql set search_path = '' as $$
declare
  v_now timestamp := now() at time zone 'Europe/Vienna';
  v_day timestamptz := date_trunc('day', now() at time zone 'Europe/Vienna') at time zone 'Europe/Vienna';
  v_h_on boolean := exists(select 1 from public.vorrat_hofer_settings where scheduled_enabled);
  v_h_ok boolean := exists(select 1 from public.vorrat_hofer_runs where trigger_source='scheduled' and status in ('ready','skipped') and created_at >= v_day);
  v_h_fails int := (select count(*) from public.vorrat_hofer_runs where trigger_source='scheduled' and status='failed' and created_at >= v_day);
begin
  if extract(isodow from v_now) <> 4 or extract(hour from v_now) > 5 then return 'ausserhalb'; end if;
  if exists(select 1 from public.vorrat_hofer_runs where status in ('queued','running'))
     or exists(select 1 from public.vorrat_lidl_runs where status in ('queued','running')) then return 'laeuft'; end if;
  if v_h_on and not v_h_ok and v_h_fails < 8 then
    perform public.vorrat_hofer_start('scheduled'); return 'hofer';
  end if;
  if exists(select 1 from public.vorrat_lidl_settings where scheduled_enabled)
     and (v_h_ok or v_h_fails >= 8 or not v_h_on)
     and not exists(select 1 from public.vorrat_lidl_runs where trigger_source='scheduled' and status in ('ready','skipped') and created_at >= v_day)
     and (select count(*) from public.vorrat_lidl_runs where trigger_source='scheduled' and status='failed' and created_at >= v_day) < 8 then
    perform public.vorrat_lidl_start('scheduled'); return 'lidl';
  end if;
  return 'fertig';
end $$;
