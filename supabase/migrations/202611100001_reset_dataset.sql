-- Settings → Reset all data. The owner erases their whole cloud dataset:
-- every row they own in every khata table (found by its owner_id column, so
-- tables added later are covered too) except their khata_sync row, which
-- gets a fresh epoch and sequence 0. The new epoch stops every other device
-- ("Cloud recovery detected" → Reconnect to cloud), and the next
-- sync_status() bootstraps the cash account and business profile again.
-- p_epoch must be the current epoch, so a stale device cannot reset by
-- accident and two resets cannot cross.
create or replace function public.reset_dataset(p_epoch uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o uuid:=auth.uid(); s public.khata_sync%rowtype; tbl text;
begin
  if o is null then raise exception 'Sign in to sync'; end if;
  select * into s from public.khata_sync where owner_id=o for update;
  if not found or p_epoch is null or s.epoch<>p_epoch then raise exception 'Dataset epoch mismatch'; end if;
  for tbl in
    select c.relname from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    join pg_catalog.pg_attribute a on a.attrelid=c.oid
    where n.nspname='public' and c.relkind='r' and c.relname like 'khata\_%'
      and c.relname<>'khata_sync' and a.attname='owner_id' and not a.attisdropped
  loop
    execute format('delete from public.%I where owner_id=$1',tbl) using o;
  end loop;
  update public.khata_sync set epoch=gen_random_uuid(),sequence=0 where owner_id=o returning * into s;
  return jsonb_build_object('epoch',s.epoch,'sequence',s.sequence,'protocol',s.protocol);
end$$;
revoke all on function public.reset_dataset(uuid) from public,anon;
grant execute on function public.reset_dataset(uuid) to authenticated;
