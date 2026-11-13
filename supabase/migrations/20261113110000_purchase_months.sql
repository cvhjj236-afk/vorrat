-- Einkaufsstatistik aus der Datenbank (nicht aus dem Client, der nur aktiven Bestand laedt).
-- Bereinigung: ausgebuchte Listenzeilen (status gone) und aus der Einkaufsliste entfernte Prospekt-Artikel sind keine Einkaeufe.
update public.vorrat_items set purchase = null where status = 'gone' and purchase is not null;
update public.vorrat_items set purchase = null
  where status = 'used' and purchase is not null and shop = 'Lidl' and bought_at >= '2026-11-12' and bought_at < '2026-11-13';

create or replace function public.vorrat_purchase_months()
returns table(month text, trips integer, articles integer, total numeric, priced integer)
language sql security definer stable set search_path = '' as $$
  with r as (
    select (bought_at at time zone 'Europe/Vienna')::date d, coalesce(shop,'-') shop, price
    from public.vorrat_items
    where household_id = public.vorrat_my_household() and public.vorrat_my_household() is not null
      and status in ('in','used') and purchase is not null and bought_at is not null
  )
  select to_char(d,'YYYY-MM'), count(distinct (d, shop))::int, count(*)::int, coalesce(sum(price),0)::numeric, count(price)::int
  from r group by 1 order by 1 desc limit 12;
$$;
grant execute on function public.vorrat_purchase_months() to authenticated;
revoke execute on function public.vorrat_purchase_months() from anon, public;
