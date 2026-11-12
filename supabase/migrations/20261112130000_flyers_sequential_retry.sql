-- Prospekte: Donnerstag 0:00-5:59 (Wien), alle 15 Min. Erst HOFER, dann Lidl.
-- Ein Quell-Lauf zaehlt als erledigt bei status ready/skipped. Laeuft einer oder ist er erledigt, passiert nichts.
-- Fehlgeschlagen -> naechster Versuch im naechsten 15-Min-Tick (max. 8 Fehlversuche pro Quelle und Nacht).
create or replace function public.vorrat_flyers_weekly() returns text language plpgsql set search_path = '' as $$
declare
  v_now timestamp := now() at time zone 'Europe/Vienna';
  v_day timestamptz := date_trunc('day', now() at time zone 'Europe/Vienna') at time zone 'Europe/Vienna';
begin
  if extract(isodow from v_now) <> 4 or extract(hour from v_now) > 5 then return 'ausserhalb'; end if;
  if exists(select 1 from public.vorrat_hofer_runs where status in ('queued','running'))
     or exists(select 1 from public.vorrat_lidl_runs where status in ('queued','running')) then return 'laeuft'; end if;
  if exists(select 1 from public.vorrat_hofer_settings where scheduled_enabled)
     and not exists(select 1 from public.vorrat_hofer_runs where trigger_source='scheduled' and status in ('ready','skipped') and created_at >= v_day)
     and (select count(*) from public.vorrat_hofer_runs where trigger_source='scheduled' and status='failed' and created_at >= v_day) < 8 then
    perform public.vorrat_hofer_start('scheduled'); return 'hofer';
  end if;
  if exists(select 1 from public.vorrat_lidl_settings where scheduled_enabled)
     and exists(select 1 from public.vorrat_hofer_runs where trigger_source='scheduled' and status in ('ready','skipped') and created_at >= v_day)
     and not exists(select 1 from public.vorrat_lidl_runs where trigger_source='scheduled' and status in ('ready','skipped') and created_at >= v_day)
     and (select count(*) from public.vorrat_lidl_runs where trigger_source='scheduled' and status='failed' and created_at >= v_day) < 8 then
    perform public.vorrat_lidl_start('scheduled'); return 'lidl';
  end if;
  return 'fertig';
end $$;

select cron.unschedule('vorrat-hofer-weekly');
select cron.unschedule('vorrat-lidl-weekly');
select cron.schedule('vorrat-flyers-weekly','*/15 * * * *','select public.vorrat_flyers_weekly();');
