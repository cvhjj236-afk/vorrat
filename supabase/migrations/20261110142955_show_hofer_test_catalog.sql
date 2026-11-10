-- Expose accepted offers from a completed five-page pilot with test_mode intact.
-- A completed regular edition takes precedence over every pilot of that edition.
create or replace function public.vorrat_hofer_catalog() returns setof public.vorrat_hofer_offers
language sql security definer set search_path = '' stable as $$
  select o.* from public.vorrat_hofer_offers o
  join public.vorrat_hofer_runs r on r.id=o.run_id
  where auth.uid() is not null and public.vorrat_my_household() is not null
    and r.status in ('ready','test_complete') and o.valid_to >= (now() at time zone 'Europe/Vienna')::date
    and r.id=(
      select preferred.id from public.vorrat_hofer_runs preferred
      where preferred.edition=r.edition and preferred.status in ('ready','test_complete')
      order by (preferred.status='ready') desc,preferred.finished_at desc,preferred.id
      limit 1
    )
  order by o.valid_from,o.category,o.name;
$$;
