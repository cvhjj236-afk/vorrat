-- Prospekte (HOFER + Lidl): nur noch 1x pro Woche, Mittwoch auf Donnerstag ab 0 Uhr (Wien).
-- Bei Fehlschlag stuendliche Wiederholung bis 3:59. Nichts taeglich.
create or replace function public.vorrat_hofer_weekly() returns uuid language plpgsql set search_path = '' as $$
begin
  if extract(isodow from now() at time zone 'Europe/Vienna')=4 and extract(hour from now() at time zone 'Europe/Vienna') between 0 and 3
    and exists(select 1 from public.vorrat_hofer_settings where scheduled_enabled)
    and not exists(select 1 from public.vorrat_hofer_runs where trigger_source='scheduled' and status<>'failed' and created_at >= date_trunc('day',now() at time zone 'Europe/Vienna') at time zone 'Europe/Vienna') then
    return public.vorrat_hofer_start('scheduled');
  end if;
  return null;
end $$;

create or replace function public.vorrat_lidl_weekly() returns uuid language plpgsql set search_path = '' as $$
begin
  if extract(isodow from now() at time zone 'Europe/Vienna')=4 and extract(hour from now() at time zone 'Europe/Vienna') between 0 and 3
    and exists(select 1 from public.vorrat_lidl_settings where scheduled_enabled)
    and not exists(select 1 from public.vorrat_lidl_runs where trigger_source='scheduled' and status<>'failed' and created_at >= date_trunc('day',now() at time zone 'Europe/Vienna') at time zone 'Europe/Vienna') then
    return public.vorrat_lidl_start('scheduled');
  end if;
  return null;
end $$;

update public.vorrat_hofer_settings set scheduled_enabled=true;
update public.vorrat_lidl_settings set scheduled_enabled=true;

select cron.unschedule('vorrat-lidl-daily');
select cron.unschedule('vorrat-hofer-weekly');
select cron.schedule('vorrat-hofer-weekly','0 * * * *','select public.vorrat_hofer_weekly();');
select cron.schedule('vorrat-lidl-weekly','5 * * * *','select public.vorrat_lidl_weekly();');
