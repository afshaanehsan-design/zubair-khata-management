-- Source documents are immutable. Corrections void and replace in one RPC.
create schema if not exists khata_private;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
revoke all on schema khata_private from public, anon, authenticated;
grant usage on schema public to authenticated,anon;

create table public.khata_sync (
  owner_id uuid primary key references auth.users(id),
  epoch uuid not null default gen_random_uuid(),
  sequence bigint not null default 0,
  protocol integer not null default 1
);
create table public.khata_records (
  owner_id uuid not null references auth.users(id), id text not null,
  kind text not null check (kind in ('party','account','settings','document','snapshot','close','audit')),
  data jsonb not null, version bigint not null check(version > 0),
  primary key(owner_id,id)
);
create index khata_kind on public.khata_records(owner_id,kind);
create index khata_doc_date on public.khata_records(owner_id,(data->>'date')) where kind='document';
create table public.khata_receipts (
  owner_id uuid not null references auth.users(id), command_id uuid not null,
  payload_hash text not null, status text not null, message text,
  sequence bigint, payload jsonb not null, received_at timestamptz not null default now(),
  primary key(owner_id,command_id)
);
create table public.khata_changes (
  owner_id uuid not null references auth.users(id), sequence bigint not null,
  command_id text not null, records jsonb not null,
  primary key(owner_id,sequence)
);
create table public.khata_postings (
  owner_id uuid not null references auth.users(id), document_id text not null,
  date date not null, account text not null, debit bigint not null
);
create index khata_ledger on public.khata_postings(owner_id,account,date);
create table public.khata_lots (
  owner_id uuid not null references auth.users(id), id text not null, ordinal bigint not null,
  date date not null, grams bigint not null, cost bigint,
  primary key(owner_id,id)
);
create table public.khata_fifo (
  owner_id uuid not null references auth.users(id), sale text not null, lot text,
  grams bigint not null, cost bigint
);
create table public.khata_cylinders (
  owner_id uuid not null references auth.users(id), key text not null,
  full_count bigint not null default 0, empty_count bigint not null default 0,
  held_count bigint not null default 0, primary key(owner_id,key)
);

do $$ declare tbl text; begin
  foreach tbl in array array['khata_sync','khata_records','khata_receipts','khata_changes','khata_postings','khata_lots','khata_fifo','khata_cylinders'] loop
    execute format('alter table public.%I enable row level security',tbl);
    execute format('create policy owner_read on public.%I for select to authenticated using (owner_id=(select auth.uid()))',tbl);
    execute format('revoke all on public.%I from anon,authenticated',tbl);
    execute format('grant select on public.%I to authenticated',tbl);
  end loop;
end $$;

create function khata_private.n(j jsonb,k text) returns bigint
language sql immutable set search_path='' as $$select coalesce(nullif(j->>k,'')::bigint,0)$$;

create function khata_private.round_div(a numeric,b numeric) returns bigint
language sql immutable set search_path='' as $$select round(a/b)::bigint$$;

create function khata_private.line(o uuid,d text,dt date,a text,v bigint) returns void
language plpgsql set search_path='' as $$begin
  if v<>0 then insert into public.khata_postings values(o,d,dt,a,v); end if;
end$$;

create function public.sync_status() returns jsonb
language plpgsql security definer set search_path='' as $$
declare o uuid:=auth.uid(); s public.khata_sync%rowtype; bundle jsonb;
begin
  if o is null then raise exception 'Sign in to sync'; end if;
  insert into public.khata_sync(owner_id) values(o) on conflict do nothing;
  select * into s from public.khata_sync where owner_id=o for update;
  if s.sequence=0 then
    insert into public.khata_records values
      (o,'cash','account','{"name":"Cash","bank":"","category":"Cash","archived":false}',1),
      (o,'business','settings','{"name":"Zubair Traders","phone":"","address":"","defaultRate":0}',1);
    select jsonb_agg(jsonb_build_object('id',id,'kind',kind,'data',data,'version',version)) into bundle from public.khata_records where owner_id=o;
    update public.khata_sync set sequence=1 where owner_id=o returning * into s;
    insert into public.khata_changes values(o,1,'bootstrap',bundle);
  end if;
  return jsonb_build_object('epoch',s.epoch,'sequence',s.sequence,'protocol',s.protocol);
end$$;

create function public.pull_changes(p_epoch uuid,p_after bigint,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o uuid:=auth.uid(); result jsonb;
begin
  if o is null or not exists(select 1 from public.khata_sync where owner_id=o and epoch=p_epoch) then raise exception 'Dataset epoch mismatch'; end if;
  if p_after<0 or p_after>(select sequence from public.khata_sync where owner_id=o) then raise exception 'Invalid sync cursor'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('sequence',q.sequence,'command_id',q.command_id,'records',q.records) order by q.sequence),'[]') into result
  from (select sequence,command_id,records from public.khata_changes where owner_id=o and sequence>p_after order by sequence limit least(greatest(p_limit,1),100)) q;
  return result;
end$$;

create function public.lookup_command(p_command_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o uuid:=auth.uid(); result jsonb;
begin
  if o is null then raise exception 'Sign in to sync'; end if;
  select jsonb_build_object('status',status,'message',message,'sequence',sequence) into result from public.khata_receipts where owner_id=o and command_id=p_command_id;
  return coalesce(result,jsonb_build_object('status','unknown'));
end$$;

create function public.apply_command(p_command jsonb) returns jsonb
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
      if k=any(array['party','account']) and exists(select 1 from public.khata_records where owner_id=o and kind=k and id<>ident and lower(regexp_replace(trim(data->>'name'),'\s+',' ','g'))=lower(regexp_replace(trim(j->>'name'),'\s+',' ','g'))) then raise exception 'This name already exists'; end if;
      if k='document' then
        financial:=true;
        if old.id is not null then
          if action<>all(array['correct','void','restore']) or coalesce((old.data->>'voided')::boolean,false) or coalesce((j->>'voided')::boolean,false)=false or (old.data-array['voided','voidReason','replacement'])<>(j-array['voided','voidReason','replacement']) then raise exception 'Posted documents require an audited reversal'; end if;
        elsif coalesce((j->>'voided')::boolean,false) then raise exception 'New document cannot be void'; end if;
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

revoke all on function public.sync_status() from public,anon;
revoke all on function public.pull_changes(uuid,bigint,integer) from public,anon;
revoke all on function public.lookup_command(uuid) from public,anon;
revoke all on function public.apply_command(jsonb) from public,anon;
grant execute on function public.sync_status(),public.pull_changes(uuid,bigint,integer),public.lookup_command(uuid),public.apply_command(jsonb) to authenticated;
revoke all on all functions in schema khata_private from public,anon,authenticated;
create function khata_private.pair(o uuid,d text,dt date,dr text,cr text,v bigint) returns void
language plpgsql set search_path='' as $$begin
  perform khata_private.line(o,d,dt,dr,v); perform khata_private.line(o,d,dt,cr,-v);
end$$;
create function khata_private.cylinder(o uuid,k text,f bigint,e bigint,h bigint) returns void
language plpgsql set search_path='' as $$begin
  insert into public.khata_cylinders values(o,k,f,e,h)
  on conflict(owner_id,key) do update set full_count=khata_cylinders.full_count+excluded.full_count,empty_count=khata_cylinders.empty_count+excluded.empty_count,held_count=khata_cylinders.held_count+excluded.held_count;
end$$;

create function khata_private.validate_document(o uuid,j jsonb,did text) returns void
language plpgsql set search_path='' as $$
declare t text:=j->>'type'; k text; val bigint; dt date; p text:=coalesce(j->>'party',''); a text:=coalesce(j->>'account','cash'); old_date text;
begin
  if t is null or t<>all(array['sale','receipt','payment','expense','purchase','transfer','discount','adjustment','stockAdjustment','cylinder','deposit','depositRefund','historicalSale','creditNote']) then raise exception 'Unknown entry type'; end if;
  dt:=(j->>'date')::date;
  if dt is null or to_char(dt,'YYYY-MM-DD')<>j->>'date' or dt<'2000-01-01' or dt>'2100-12-31' then raise exception 'Choose a valid date'; end if;
  foreach k in array array['amount','cash','bank','rate','extraGrams','grams','cost','depositCharge','fullDelta','emptyDelta','heldDelta','count','occurredAt'] loop
    val:=khata_private.n(j,k);
    if abs(val)>9000000000000 then raise exception 'Number exceeds supported range'; end if;
    if k=any(array['cash','bank','rate','extraGrams','cost','depositCharge','count']) and val<0 then raise exception 'Amounts and quantities cannot be negative'; end if;
  end loop;
  foreach k in array array['11800','15000','45000'] loop
    if khata_private.n(j->'quantities',k)<0 or khata_private.n(j->'quantities',k)>100000 or khata_private.n(j->'returned',k)<0 or khata_private.n(j->'returned',k)>100000 then raise exception 'Invalid cylinder count'; end if;
  end loop;
  if (p<>'' or t=any(array['sale','receipt','payment','purchase','discount','deposit','depositRefund','creditNote'])) and not exists(select 1 from public.khata_records where owner_id=o and id=p and kind='party') then raise exception 'Choose a party'; end if;
  if khata_private.n(j,'bank')>0 and not exists(select 1 from public.khata_records where owner_id=o and id=j->>'bankAccount' and kind='account' and id<>'cash') then raise exception 'Choose a bank account'; end if;
  if t=any(array['payment','expense','purchase','transfer','deposit','depositRefund']) and not exists(select 1 from public.khata_records where owner_id=o and id=a and kind='account') then raise exception 'Choose a money account'; end if;
  if t=any(array['payment','expense','transfer','discount','deposit','depositRefund','historicalSale']) and khata_private.n(j,'amount')<=0 then raise exception 'Enter an amount greater than zero'; end if;
  if t='sale' then
    if khata_private.n(j,'rate')<=0 or (khata_private.n(j->'quantities','11800')+khata_private.n(j->'quantities','15000')+khata_private.n(j->'quantities','45000')+khata_private.n(j,'extraGrams'))<=0 then raise exception 'Enter a quantity and rate'; end if;
    if exists(select 1 from public.khata_records where owner_id=o and kind='document' and id<>did and data->>'type'='historicalSale' and data->>'date'=j->>'date' and coalesce((data->>'voided')::boolean,false)=false) then raise exception 'Void the historical summary before adding detailed sales'; end if;
  end if;
  if t='receipt' and khata_private.n(j,'cash')+khata_private.n(j,'bank')<=0 then raise exception 'Enter a collection amount'; end if;
  if t='purchase' and (khata_private.n(j,'grams')<=0 or khata_private.n(j,'rate')<=0 or khata_private.n(j,'rateUnit')<>all(array[1000,11800,1000000]) or khata_private.n(j,'amount')<0) then raise exception 'Enter purchase weight and rate'; end if;
  if t='transfer' and (a=j->>'toAccount' or not exists(select 1 from public.khata_records where owner_id=o and id=j->>'toAccount' and kind='account')) then raise exception 'Choose a different destination account'; end if;
  if t=any(array['adjustment','stockAdjustment','cylinder','creditNote']) and length(trim(coalesce(j->>'note','')))=0 then raise exception 'A reason is required'; end if;
  if t='adjustment' then
    k:=j->>'target';
    if khata_private.n(j,'amount')=0 or k is null or not ((k like 'money:%' and exists(select 1 from public.khata_records where owner_id=o and id=substr(k,7) and kind='account')) or (split_part(k,':',1)=any(array['ar','ap','deposit']) and exists(select 1 from public.khata_records where owner_id=o and id=substr(k,strpos(k,':')+1) and kind='party'))) then raise exception 'Choose a balance and nonzero correction'; end if;
  end if;
  if t='stockAdjustment' and (khata_private.n(j,'grams')=0 or (khata_private.n(j,'grams')<0 and khata_private.n(j,'cost')<>0)) then raise exception 'Enter a valid stock correction'; end if;
  if t='cylinder' then
    if khata_private.n(j,'size')<>all(array[11800,15000,45000]) or (khata_private.n(j,'fullDelta')=0 and khata_private.n(j,'emptyDelta')=0 and khata_private.n(j,'heldDelta')=0) then raise exception 'Enter cylinder count changes'; end if;
    if khata_private.n(j,'heldDelta')<>0 and not exists(select 1 from public.khata_records where owner_id=o and id=p and kind='party') then raise exception 'Choose a party'; end if;
  end if;
  if t='historicalSale' and (khata_private.n(j,'grams')<=0 or exists(select 1 from public.khata_records where owner_id=o and kind='document' and id<>did and data->>'type'=any(array['sale','historicalSale']) and data->>'date'=j->>'date' and coalesce((data->>'voided')::boolean,false)=false)) then raise exception 'Historical summaries cannot overlap detailed sales'; end if;
  if t='creditNote' then
    if not exists(select 1 from public.khata_records where owner_id=o and id=j->>'sourceInvoice' and kind='document' and data->>'type'='sale' and data->>'party'=p and (data->>'date')::date<=dt and coalesce((data->>'voided')::boolean,false)=false and data->'quantities'=j->'quantities' and khata_private.n(data,'rate')=khata_private.n(j,'rate') and khata_private.n(data,'extraGrams')=khata_private.n(j,'extraGrams')) or exists(select 1 from public.khata_records where owner_id=o and kind='document' and id<>did and data->>'type'='creditNote' and data->>'sourceInvoice'=j->>'sourceInvoice' and coalesce((data->>'voided')::boolean,false)=false) then raise exception 'Choose an invoice without an existing credit note'; end if;
  end if;
  if j ? 'allocations' and jsonb_typeof(j->'allocations')<>'object' then raise exception 'Invalid allocation'; end if;
  if j ? 'allocations' then
    val:=0;
    for k in select jsonb_object_keys(j->'allocations') loop
      if khata_private.n(j->'allocations',k)<0 or not exists(select 1 from public.khata_records where owner_id=o and id=k and kind='document' and data->>'party'=p and data->>'type'='sale' and coalesce((data->>'voided')::boolean,false)=false) then raise exception 'Invalid allocation'; end if;
      val:=val+khata_private.n(j->'allocations',k);
    end loop;
    if val>khata_private.n(j,'cash')+khata_private.n(j,'bank') then raise exception 'Allocation exceeds collection'; end if;
  end if;
end$$;

create function khata_private.consume(o uuid,d text,dt date,g bigint) returns bigint
language plpgsql set search_path='' as $$
declare lot record; remaining bigint:=g; used bigint; c bigint; total bigint:=0; cost_account text;
begin
  select case when data->>'type'='stockAdjustment' then 'expense:Stock loss' else 'cogs' end into cost_account from public.khata_records where owner_id=o and id=d;
  for lot in select * from public.khata_lots where owner_id=o and grams>0 order by ordinal loop
    exit when remaining<=0;
    used:=least(remaining,lot.grams);
    if lot.cost is null then c:=null; else c:=khata_private.round_div(lot.cost::numeric*used,lot.grams); total:=total+c; perform khata_private.pair(o,d,dt,cost_account,'inventory',c); end if;
    insert into public.khata_fifo values(o,d,lot.id,used,c);
    update public.khata_lots set grams=grams-used,cost=cost-c where owner_id=o and id=lot.id;
    remaining:=remaining-used;
  end loop;
  if remaining>0 then insert into public.khata_fifo values(o,d,null,remaining,null); end if;
  return remaining;
end$$;

create function khata_private.rebuild(o uuid) returns void
language plpgsql set search_path='' as $$
declare r record; j jsonb; original jsonb; t text; dt date; p text; a text; bank text; amount bigint; cash bigint; b bigint; g bigint; bill bigint; cyl bigint; extra bigint; unit bigint; cost bigint; seq bigint:=0; size text; issued bigint; returned bigint; shortage bigint:=0; covered bigint; reserved bigint;
begin
  delete from public.khata_postings where owner_id=o;
  delete from public.khata_lots where owner_id=o;
  delete from public.khata_fifo where owner_id=o;
  delete from public.khata_cylinders where owner_id=o;
  for r in select id,data from public.khata_records where owner_id=o and kind='document' and coalesce((data->>'voided')::boolean,false)=false order by data->>'date',khata_private.n(data,'occurredAt'),id loop
    j:=r.data; t:=j->>'type'; dt:=(j->>'date')::date; p:=coalesce(j->>'party',''); a:=coalesce(j->>'account','cash'); bank:=coalesce(j->>'bankAccount',''); amount:=khata_private.n(j,'amount'); cash:=khata_private.n(j,'cash'); b:=khata_private.n(j,'bank'); seq:=seq+1;
    case t
    when 'sale' then
      g:=11800*khata_private.n(j->'quantities','11800')+15000*khata_private.n(j->'quantities','15000')+45000*khata_private.n(j->'quantities','45000');
      cyl:=khata_private.round_div(g::numeric*khata_private.n(j,'rate'),1180000)*100;
      bill:=khata_private.round_div((g+khata_private.n(j,'extraGrams'))::numeric*khata_private.n(j,'rate'),1180000)*100; extra:=bill-cyl;
      perform khata_private.line(o,r.id,dt,'ar:'||p,bill+khata_private.n(j,'depositCharge'));
      perform khata_private.line(o,r.id,dt,'revenue:gas',-cyl); perform khata_private.line(o,r.id,dt,'revenue:bulk',-extra); perform khata_private.line(o,r.id,dt,'deposit:'||p,-khata_private.n(j,'depositCharge'));
      perform khata_private.pair(o,r.id,dt,'money:cash','ar:'||p,cash); perform khata_private.pair(o,r.id,dt,'money:'||bank,'ar:'||p,b);
      shortage:=shortage+khata_private.consume(o,r.id,dt,g);
      if coalesce((j->>'customerOwned')::boolean,false)=false then
        foreach size in array array['11800','15000','45000'] loop
          issued:=khata_private.n(j->'quantities',size); returned:=khata_private.n(j->'returned',size);
          perform khata_private.cylinder(o,size,-issued,returned,0); perform khata_private.cylinder(o,p||':'||size,0,0,issued-returned);
        end loop;
      end if;
    when 'receipt' then
      a:=case when coalesce((j->>'supplierRefund')::boolean,false) then 'ap:' else 'ar:' end||p;
      perform khata_private.pair(o,r.id,dt,'money:cash',a,cash); perform khata_private.pair(o,r.id,dt,'money:'||bank,a,b);
    when 'payment' then
      perform khata_private.pair(o,r.id,dt,(case when coalesce((j->>'supplierPayment')::boolean,false) then 'ap:' else 'ar:' end)||p,'money:'||a,amount);
    when 'expense' then perform khata_private.pair(o,r.id,dt,'expense:'||coalesce(j->>'category','General'),'money:'||a,amount);
    when 'purchase' then
      unit:=khata_private.n(j,'rateUnit'); g:=khata_private.n(j,'grams'); cost:=khata_private.round_div(g::numeric*khata_private.n(j,'rate'),unit*100)*100;
      perform khata_private.pair(o,r.id,dt,'inventory','ap:'||p,cost); perform khata_private.pair(o,r.id,dt,'ap:'||p,'money:'||a,amount);
      covered:=least(shortage,g); reserved:=khata_private.round_div(cost::numeric*covered,g);
      if covered>0 then perform khata_private.pair(o,r.id,dt,'cogs:shortage','inventory',reserved); end if;
      insert into public.khata_lots values(o,r.id,seq,dt,g-covered,cost-reserved); shortage:=shortage-covered;
    when 'transfer' then perform khata_private.pair(o,r.id,dt,'money:'||(j->>'toAccount'),'money:'||a,amount);
    when 'discount' then perform khata_private.pair(o,r.id,dt,'expense:Write-off','ar:'||p,amount);
    when 'adjustment' then perform khata_private.pair(o,r.id,dt,j->>'target','equity:opening',amount);
    when 'stockAdjustment' then
      g:=khata_private.n(j,'grams');
      if g>0 then
        cost:=case when coalesce((j->>'costKnown')::boolean,false) then khata_private.n(j,'cost') else null end;
        covered:=least(shortage,g); reserved:=case when cost is null then null else khata_private.round_div(cost::numeric*covered,g) end;
        insert into public.khata_lots values(o,r.id,seq,dt,g-covered,cost-reserved); shortage:=shortage-covered;
        if cost is not null then perform khata_private.pair(o,r.id,dt,'inventory','equity:opening',cost); if covered>0 then perform khata_private.pair(o,r.id,dt,'cogs:shortage','inventory',reserved); end if; end if;
      else shortage:=shortage+khata_private.consume(o,r.id,dt,-g); end if;
    when 'cylinder' then
      size:=khata_private.n(j,'size')::text; perform khata_private.cylinder(o,size,khata_private.n(j,'fullDelta'),khata_private.n(j,'emptyDelta'),0);
      if p<>'' then perform khata_private.cylinder(o,p||':'||size,0,0,khata_private.n(j,'heldDelta')); end if;
    when 'deposit' then perform khata_private.pair(o,r.id,dt,'money:'||a,'deposit:'||p,amount);
    when 'depositRefund' then perform khata_private.pair(o,r.id,dt,'deposit:'||p,'money:'||a,amount);
    when 'historicalSale' then shortage:=shortage+khata_private.consume(o,r.id,dt,khata_private.n(j,'grams'));
    when 'creditNote' then
      select data into original from public.khata_records where owner_id=o and id=j->>'sourceInvoice' and kind='document' and coalesce((data->>'voided')::boolean,false)=false;
      if original is null then raise exception 'Void the related credit note first'; end if;
      g:=11800*khata_private.n(original->'quantities','11800')+15000*khata_private.n(original->'quantities','15000')+45000*khata_private.n(original->'quantities','45000');
      cyl:=khata_private.round_div(g::numeric*khata_private.n(original,'rate'),1180000)*100;
      bill:=khata_private.round_div((g+khata_private.n(original,'extraGrams'))::numeric*khata_private.n(original,'rate'),1180000)*100;
      perform khata_private.line(o,r.id,dt,'revenue:gas',cyl); perform khata_private.line(o,r.id,dt,'revenue:bulk',bill-cyl); perform khata_private.line(o,r.id,dt,'ar:'||p,-bill);
      if coalesce((j->>'stockReturned')::boolean,false) and g>0 then
        if exists(select 1 from public.khata_fifo f where f.owner_id=o and f.sale=j->>'sourceInvoice' and f.cost is null) then raise exception 'Record the missing purchase cost before returning stock'; end if;
        select coalesce(sum(f.cost),0) into cost from public.khata_fifo f where f.owner_id=o and f.sale=j->>'sourceInvoice';
        perform khata_private.pair(o,r.id,dt,'inventory','cogs',cost);
        covered:=least(shortage,g);reserved:=khata_private.round_div(cost::numeric*covered,g);shortage:=shortage-covered;
        if covered>0 then perform khata_private.pair(o,r.id,dt,'cogs:shortage','inventory',reserved); end if;
        insert into public.khata_lots values(o,r.id,seq,dt,g-covered,cost-reserved);
      end if;
    else raise exception 'Unknown entry type';
    end case;
  end loop;
  if exists(select 1 from public.khata_postings where owner_id=o group by document_id having sum(debit)<>0) then raise exception 'Unbalanced accounting document'; end if;
  if exists(select 1 from public.khata_cylinders where owner_id=o and held_count<0) then raise exception 'Cylinder returns exceed this party’s outstanding cylinders'; end if;
  if exists(select 1 from public.khata_postings where owner_id=o and account like 'deposit:%' group by account having sum(debit)>0) then raise exception 'Refund exceeds the refundable deposit'; end if;
end$$;

revoke all on all functions in schema khata_private from public,anon,authenticated;



create function khata_private.canonical_document(j jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare common text[]:=array['type','date','occurredAt','party','note','reference','voided','voidReason','replacement','replaces','restoredFrom']; fields text[];
begin
  fields:=case j->>'type'
    when 'sale' then array['quantities','returned','rate','extraGrams','depositCharge','cash','bank','bankAccount','customerOwned','vehicle','dueDate','allocations']
    when 'receipt' then array['cash','bank','bankAccount','supplierRefund','allocations']
    when 'payment' then array['amount','account','supplierPayment','branch','customerNote']
    when 'expense' then array['amount','account','category']
    when 'purchase' then array['grams','rate','rateUnit','amount','account','vehicle']
    when 'transfer' then array['amount','account','toAccount']
    when 'discount' then array['amount']
    when 'adjustment' then array['target','amount']
    when 'stockAdjustment' then array['grams','cost','costKnown']
    when 'cylinder' then array['size','fullDelta','emptyDelta','heldDelta','cylinderMode','count','acquireFull']
    when 'deposit' then array['amount','account']
    when 'depositRefund' then array['amount','account']
    when 'historicalSale' then array['grams','amount']
    when 'creditNote' then array['sourceInvoice','stockReturned','quantities','rate','extraGrams']
    else array[]::text[] end;
  return (select coalesce(jsonb_object_agg(key,value),'{}') from jsonb_each(j) where key=any(common||fields));
end$$;
revoke all on all functions in schema khata_private from public,anon,authenticated;
