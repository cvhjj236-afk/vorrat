-- Preis eingesortierter Einkaeufe: zaehlt zum Lager-Einkaufswert, aber nicht doppelt in der Monatsstatistik.
alter table public.vorrat_items add column if not exists extra_price numeric;
