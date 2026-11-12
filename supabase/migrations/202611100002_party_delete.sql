-- Deleting a party that has no entries. A deleted party keeps its row (the
-- khata never erases records, so the change syncs like any other) with
-- data.deleted = true; the app hides it everywhere.
--   * only a party can be deleted, and only while no live (not voided) document
--     belongs to it
--   * a deleted party cannot be restored and takes no new documents
--   * a deleted party's name is free again
-- apply_command is otherwise unchanged from 202611070001_khata.sql.
create or replace function public.apply_command(p_command jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o uuid:=auth.uid(); s public.khata_sync%rowtype; old public.khata_records%rowtype;
  receipt public.khata_receipts%rowtype; change jsonb; j jsonb; cid uuid; hash text;
  ident text; k text; expected bigint; result_status text:='accepted'; message text;
  changed text[]:=array[]::text[]; bundle jsonb; action text; dt date; financial boolean:=false; n integer;
begin
  if o is null then raise exception 'Sign in to sync'; end if;
  select * into s from public.khata_sync where owner_id=o for update;
  if not found then raise exception 'Call sync_status first'; end if;
  cid:=(p_command->>'command_id')::uuid; action:=p_command->>'action';
  hash:=encode(extensions.digest(p_command::text,'sha256'),'hex');
  select * into receipt from public.khata_receipts where owner_id=o and command_id=cid;
  if found then
    if receipt.payload_hash<>hash then raise exception 'Command ID reused with a different payload'; end if;
    return jsonb_build_object('status',receipt.status,'message',receipt.message,'sequence',receipt.sequence);
  end if;
  -- This nested block is a savepoint: a rejected compound action leaves no partial writes.
  begin
    if (p_command->>'epoch')::uuid<>s.epoch or p_command->>'epoch' is null then raise exception 'Dataset epoch mismatch'; end if;
    if jsonb_typeof(p_command->'changes')<>'array' or jsonb_array_length(p_command->'changes')=0 or octet_length(p_command::text)>5000000 then raise exception 'Invalid command'; end if;
    if action<>all(array['save','correct','void','restore','close','reopen']) or action is null then raise exception 'Invalid action'; end if;
    if action=any(array['correct','void','restore','close','reopen']) and length(trim(coalesce(p_command->>'reason','')))=0 then raise exception 'A reason is required'; end if;
    for change in select value from jsonb_array_elements(p_command->'changes') loop
      ident:=change->>'id'; k:=change->>'kind'; j:=change->'data'; expected:=(change->>'expected_version')::bigint;
      if k='document' then j:=khata_private.canonical_document(j); end if;
      if ident is null or length(ident)>120 or ident=any(changed) or expected is null or jsonb_typeof(j)<>'object' then raise exception 'Invalid change'; end if;
      if k<>all(array['party','account','settings','document','snapshot','close']) or k is null then raise exception 'Invalid record kind'; end if;
      select * into old from public.khata_records where owner_id=o and id=ident;
      if coalesce(old.version,0)<>expected then raise exception using errcode='40001',message='This record changed on another device. Review your changes.'; end if;
      if old.id is not null and old.kind<>k then raise exception 'Record kind cannot change'; end if;
      if k='settings' and ident<>'business' then raise exception 'Invalid settings record'; end if;
      if ident='cash' and (k<>'account' or coalesce((j->>'archived')::boolean,false)) then raise exception 'Cash account must remain available'; end if;
      if k=any(array['party','account','settings']) and length(trim(coalesce(j->>'name','')))=0 then raise exception 'Enter a name'; end if;
      if coalesce((j->>'deleted')::boolean,false) then
        if k<>'party' then raise exception 'Only a party can be deleted'; end if;
        if exists(select 1 from public.khata_records where owner_id=o and kind='document' and data->>'party'=ident and coalesce((data->>'voided')::boolean,false)=false) then raise exception 'This party has entries and cannot be deleted'; end if;
      end if;
      if old.id is not null and coalesce((old.data->>'deleted')::boolean,false) and not coalesce((j->>'deleted')::boolean,false) then raise exception 'A deleted party cannot be restored'; end if;
      if k=any(array['party','account']) and not coalesce((j->>'deleted')::boolean,false) and exists(select 1 from public.khata_records where owner_id=o and kind=k and id<>ident and not coalesce((data->>'deleted')::boolean,false) and lower(regexp_replace(trim(data->>'name'),'\s+',' ','g'))=lower(regexp_replace(trim(j->>'name'),'\s+',' ','g'))) then raise exception 'This name already exists'; end if;
      if k='document' then
        financial:=true;
        if old.id is not null then
          if action<>all(array['correct','void','restore']) or coalesce((old.data->>'voided')::boolean,false) or coalesce((j->>'voided')::boolean,false)=false or (old.data-array['voided','voidReason','replacement'])<>(j-array['voided','voidReason','replacement']) then raise exception 'Posted documents require an audited reversal'; end if;
        elsif coalesce((j->>'voided')::boolean,false) then raise exception 'New document cannot be void'; end if;
        if not coalesce((j->>'voided')::boolean,false) and coalesce(j->>'party','')<>'' and exists(select 1 from public.khata_records where owner_id=o and kind='party' and id=j->>'party' and coalesce((data->>'deleted')::boolean,false)) then raise exception 'Choose a party'; end if;
        dt:=(j->>'date')::date;
        if exists(select 1 from public.khata_records where owner_id=o and kind='close' and (data->>'closed')::boolean and (data->>'date')::date>=dt) then raise exception 'Reopen this day before changing it'; end if;
      end if;
      if k='close' then
        if action<>all(array['close','reopen']) then raise exception 'Invalid close action'; end if;
        dt:=(j->>'date')::date;
        if ident<>'close:'||to_char(dt,'YYYY-MM-DD') or khata_private.n(j,'expected_sequence')<>s.sequence then raise exception using errcode='40001',message='New changes arrived. Synchronize before closing.'; end if;
        if action='close' then
          if (j->>'closed')::boolean<>true then raise exception 'Invalid close state'; end if;
          j:=j||jsonb_build_object('balances',(select coalesce(jsonb_object_agg(q.account,q.total),'{}') from (select account,sum(debit) total from public.khata_postings where owner_id=o and date<=dt group by account) q),'closedAt',now());
        else
          if (j->>'closed')::boolean<>false then raise exception 'Invalid reopen state'; end if;
        end if;
      end if;
      insert into public.khata_records values(o,ident,k,j,expected+1) on conflict(owner_id,id) do update set data=excluded.data,version=excluded.version;
      changed:=array_append(changed,ident);
    end loop;
    for ident in select unnest(changed) loop
      select * into old from public.khata_records where owner_id=o and id=ident;
      if old.kind='document' and coalesce((old.data->>'voided')::boolean,false)=false then perform khata_private.validate_document(o,old.data,old.id); end if;
    end loop;
    if action='reopen' then
      for old in select * from public.khata_records where owner_id=o and kind='close' and not(id=any(changed)) and (data->>'date')::date>=dt and (data->>'closed')::boolean loop
        update public.khata_records set data=data||jsonb_build_object('closed',false,'reason',p_command->>'reason'),version=version+1 where owner_id=o and id=old.id;
        changed:=array_append(changed,old.id);
      end loop;
    end if;
    if financial then perform khata_private.rebuild(o); end if;
    ident:='audit:'||cid::text;
    insert into public.khata_records values(o,ident,'audit',jsonb_build_object('command_id',cid,'action',action,'reason',p_command->>'reason','device',p_command->>'device_id','receivedAt',now(),'recordIds',to_jsonb(changed)),1);
    changed:=array_append(changed,ident);
    update public.khata_sync set sequence=sequence+1 where owner_id=o returning * into s;
    select jsonb_agg(jsonb_build_object('id',id,'kind',kind,'data',data,'version',version) order by id) into bundle from public.khata_records where owner_id=o and id=any(changed);
    insert into public.khata_changes values(o,s.sequence,cid::text,bundle);
  exception
    when serialization_failure then result_status:='conflict'; message:=sqlerrm;
    when others then result_status:='rejected'; message:=sqlerrm;
  end;
  insert into public.khata_receipts(owner_id,command_id,payload_hash,status,message,sequence,payload) values(o,cid,hash,result_status,message,case when result_status='accepted' then s.sequence else null end,p_command);
  return jsonb_build_object('status',result_status,'message',message,'sequence',case when result_status='accepted' then s.sequence else null end);
end$$;
