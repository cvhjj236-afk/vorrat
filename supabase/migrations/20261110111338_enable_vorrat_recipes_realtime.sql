do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'vorrat_recipes'
  ) then
    alter publication supabase_realtime add table public.vorrat_recipes;
  end if;
end;
$$;
