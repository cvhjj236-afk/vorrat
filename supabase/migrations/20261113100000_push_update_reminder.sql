-- Erinnerungen bearbeiten: gleiche Pruefungen wie vorrat_push_save_reminder, aber UPDATE auf bestehende Zeile.
create or replace function public.vorrat_push_update_reminder(
  p_id uuid, p_recipient uuid, p_title text, p_body text, p_items text[], p_include_list boolean,
  p_repeat text, p_date date, p_time time
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_hh uuid := public.vorrat_my_household(); v_at timestamptz;
begin
  if auth.uid() is null or v_hh is null then raise exception 'not allowed'; end if;
  if not exists(select 1 from public.vorrat_push_reminders where id = p_id and household_id = v_hh) then raise exception 'not found'; end if;
  if not exists(select 1 from public.vorrat_members where user_id = p_recipient and household_id = v_hh) then
    raise exception 'recipient not in household';
  end if;
  if p_repeat not in ('once','daily') then raise exception 'bad repeat'; end if;
  if p_repeat = 'once' then
    v_at := ((p_date + p_time) at time zone 'Europe/Vienna');
  else
    v_at := (((now() at time zone 'Europe/Vienna')::date + p_time) at time zone 'Europe/Vienna');
    if v_at <= now() then v_at := ((((now() at time zone 'Europe/Vienna')::date + 1) + p_time) at time zone 'Europe/Vienna'); end if;
  end if;
  if p_repeat = 'once' and v_at <= now() then raise exception 'in the past'; end if;
  update public.vorrat_push_reminders set recipient_id = p_recipient, title = left(btrim(p_title),80),
    body = left(coalesce(p_body,''),500), item_names = coalesce(p_items,'{}'), include_list = coalesce(p_include_list,false),
    repeat = p_repeat, send_at = v_at, active = true, last_status = null
  where id = p_id;
  return true;
end $$;
grant execute on function public.vorrat_push_update_reminder(uuid,uuid,text,text,text[],boolean,text,date,time) to authenticated;
revoke execute on function public.vorrat_push_update_reminder(uuid,uuid,text,text,text[],boolean,text,date,time) from anon, public;
