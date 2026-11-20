-- Wöchentliches Aufräumen der Prospekt-Daten (HOFER + Lidl), damit kein Datenfriedhof entsteht.
-- Regeln:
--  * Angebote löschen, deren Gültigkeit seit mehr als 7 Tagen abgelaufen ist
--  * Testlauf-Angebote (test_mode) älter als 7 Tage löschen
--  * Seiten-Rohdaten (vorrat_*_pages: OCR/Review-JSON) von Läufen älter als 30 Tage löschen
--  * Läufe (vorrat_*_runs) bleiben erhalten: sie sind klein und liefern Fingerprint/Edition für die Deduplizierung
-- Einkaufslisten-Einträge (vorrat_items) hängen nicht an Angeboten (eigene ID, Preis wird kopiert) und sind nicht betroffen.
create or replace function public.vorrat_flyers_cleanup()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_today date := (now() at time zone 'Europe/Vienna')::date;
  v_ho int; v_li int; v_hp int; v_lp int;
begin
  delete from public.vorrat_hofer_offers o
   where o.valid_to < v_today - 7
      or (o.test_mode and exists (select 1 from public.vorrat_hofer_runs r where r.id=o.run_id and r.created_at < now() - interval '7 days'));
  get diagnostics v_ho = row_count;

  delete from public.vorrat_lidl_offers o
   where o.valid_to < v_today - 7
      or (o.test_mode and exists (select 1 from public.vorrat_lidl_runs r where r.id=o.run_id and r.created_at < now() - interval '7 days'));
  get diagnostics v_li = row_count;

  delete from public.vorrat_hofer_pages p
   using public.vorrat_hofer_runs r
   where r.id=p.run_id and r.created_at < now() - interval '30 days' and r.status not in ('queued','running');
  get diagnostics v_hp = row_count;

  delete from public.vorrat_lidl_pages p
   using public.vorrat_lidl_runs r
   where r.id=p.run_id and r.created_at < now() - interval '30 days' and r.status not in ('queued','running');
  get diagnostics v_lp = row_count;

  return format('hofer_offers=%s lidl_offers=%s hofer_pages=%s lidl_pages=%s', v_ho, v_li, v_hp, v_lp);
end $$;

revoke all on function public.vorrat_flyers_cleanup() from public, anon, authenticated;

-- Donnerstag 05:30 UTC = 06:30/07:30 Wien, nach dem Import-Fenster (Do 0:00-5:59 Wien).
select cron.unschedule('vorrat-flyers-cleanup') where exists (select 1 from cron.job where jobname='vorrat-flyers-cleanup');
select cron.schedule('vorrat-flyers-cleanup', '30 5 * * 4', 'select public.vorrat_flyers_cleanup();');
