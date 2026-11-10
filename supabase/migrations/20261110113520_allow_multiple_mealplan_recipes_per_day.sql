alter table public.vorrat_mealplan
  drop constraint vorrat_mealplan_pkey;

alter table public.vorrat_mealplan
  add constraint vorrat_mealplan_pkey
  primary key (household_id, plan_date, recipe_name);
