alter table public.vorrat_recipes add column categories text[] not null default '{}'::text[];
alter table public.vorrat_recipes add constraint vorrat_recipes_categories_check check (categories <@ array['Frühstück','Hauptgerichte','Suppen & Eintöpfe','Salate & Beilagen','Snacks & Kleinigkeiten','Nachspeisen & Backen']::text[] and array_position(categories, null) is null);
