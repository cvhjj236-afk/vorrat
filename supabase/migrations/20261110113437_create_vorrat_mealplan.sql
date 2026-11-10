create table public.vorrat_mealplan (
  household_id uuid not null default public.vorrat_my_household()
    references public.vorrat_households(id) on delete cascade,
  plan_date date not null,
  recipe_name text not null
    check (char_length(btrim(recipe_name)) between 1 and 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (household_id, plan_date)
);

alter table public.vorrat_mealplan enable row level security;

create policy "vorrat_mealplan_all"
on public.vorrat_mealplan
for all
to authenticated
using (household_id = public.vorrat_my_household())
with check (household_id = public.vorrat_my_household());

grant select, insert, update, delete
on public.vorrat_mealplan to authenticated;

alter publication supabase_realtime
add table public.vorrat_mealplan;
