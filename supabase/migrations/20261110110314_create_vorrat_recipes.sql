create table public.vorrat_recipes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null default public.vorrat_my_household()
    references public.vorrat_households(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  ingredients jsonb not null default '[]'::jsonb
    check (jsonb_typeof(ingredients) = 'array'),
  instructions text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index vorrat_recipes_household_id_idx
  on public.vorrat_recipes (household_id);

alter table public.vorrat_recipes enable row level security;

create policy vorrat_recipes_all
  on public.vorrat_recipes
  for all to authenticated
  using (household_id = public.vorrat_my_household())
  with check (household_id = public.vorrat_my_household());

grant select, insert, update, delete
  on public.vorrat_recipes to authenticated;
