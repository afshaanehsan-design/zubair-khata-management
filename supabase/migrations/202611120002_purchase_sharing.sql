-- Purchase sharing: bulk KG charged at exact FIFO cost, outside own sales.
-- Prices are recorded on posting. Later purchase-cost corrections leave a
-- visible cost-recovery difference instead of changing historical party debt.
create or replace function khata_private.canonical_document(j jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare common text[]:=array['type','date','occurredAt','party','note','reference','voided','voidReason','replacement','replaces','restoredFrom','form']; fields text[];
begin
  fields:=case j->>'type'
    when 'sale' then array['bulkAtCost','bulkCost','quantities','returned','rate','extraGrams','depositCharge','cash','bank','bankAccount','direct','directParty','directBank','bankLines','customerOwned','vehicle','dueDate','allocations']
    when 'receipt' then array['cash','bank','bankAccount','direct','directParty','directBank','bankLines','supplierRefund','allocations','vehicle']
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
    when 'creditNote' then array['bulkAtCost','bulkCost','sourceInvoice','stockReturned','quantities','rate','extraGrams']
    else array[]::text[] end;
  return (select coalesce(jsonb_object_agg(key,value),'{}') from jsonb_each(j) where key=any(common||fields));
end$$;

create or replace function khata_private.validate_document(o uuid,j jsonb,did text) returns void
language plpgsql set search_path='' as $$
declare t text:=j->>'type'; k text; val bigint; dt date; p text:=coalesce(j->>'party',''); a text:=coalesce(j->>'account','cash'); old_date text; l jsonb; collected bigint:=khata_private.n(j,'cash')+khata_private.n(j,'bank')+khata_private.n(j,'direct');
begin
  if (j ? 'bulkAtCost' and jsonb_typeof(j->'bulkAtCost')<>'boolean') or (j ? 'bulkCost' and (jsonb_typeof(j->'bulkCost')<>'number' or (j->>'bulkCost')!~'^[0-9]+$')) or (j->'bulkAtCost'='true'::jsonb and (t<>all(array['sale','creditNote']) or khata_private.n(j,'extraGrams')<=0 or not (j ? 'bulkCost') or (khata_private.n(j->'quantities','11800')+khata_private.n(j->'quantities','15000')+khata_private.n(j->'quantities','45000')=0 and khata_private.n(j,'depositCharge')<>0))) then raise exception 'Choose a valid purchase-share quantity and cost'; end if;
  if t is null or t<>all(array['sale','receipt','payment','expense','purchase','transfer','discount','adjustment','stockAdjustment','cylinder','deposit','depositRefund','historicalSale','creditNote']) then raise exception 'Unknown entry type'; end if;
  dt:=(j->>'date')::date;
  if dt is null or to_char(dt,'YYYY-MM-DD')<>j->>'date' or dt<'2000-01-01' or dt>'2100-12-31' then raise exception 'Choose a valid date'; end if;
  foreach k in array array['amount','cash','bank','direct','rate','extraGrams','bulkCost','grams','cost','depositCharge','fullDelta','emptyDelta','heldDelta','count','occurredAt'] loop
    val:=khata_private.n(j,k);
    if abs(val)>9000000000000 then raise exception 'Number exceeds supported range'; end if;
    if k=any(array['cash','bank','direct','rate','extraGrams','cost','depositCharge','count']) and val<0 then raise exception 'Amounts and quantities cannot be negative'; end if;
  end loop;
  foreach k in array array['11800','15000','45000'] loop
    if khata_private.n(j->'quantities',k)<0 or khata_private.n(j->'quantities',k)>100000 or khata_private.n(j->'returned',k)<0 or khata_private.n(j->'returned',k)>100000 then raise exception 'Invalid cylinder count'; end if;
  end loop;
  if (p<>'' or t=any(array['sale','receipt','payment','purchase','discount','deposit','depositRefund','creditNote'])) and not exists(select 1 from public.khata_records where owner_id=o and id=p and kind='party') then raise exception 'Choose a party'; end if;
  if khata_private.n(j,'bank')>0 and not exists(select 1 from public.khata_records where owner_id=o and id=j->>'bankAccount' and kind='account' and id<>'cash') then raise exception 'Choose a bank account'; end if;
  if khata_private.n(j,'direct')>0 and (t<>all(array['sale','receipt']) or coalesce((j->>'supplierRefund')::boolean,false) or coalesce(j->>'directParty','')=p or not exists(select 1 from public.khata_records where owner_id=o and id=j->>'directParty' and kind='party' and not coalesce((data->>'deleted')::boolean,false))) then raise exception 'Choose the party that was paid directly'; end if;
  if length(coalesce(j->>'directBank',''))>120 then raise exception 'Invalid bank lines'; end if;
  if j->'bankLines' is not null and j->'bankLines'<>'null'::jsonb then
    if jsonb_typeof(j->'bankLines')<>'array' then raise exception 'Invalid bank lines'; end if;
    if jsonb_array_length(j->'bankLines')>20 or (jsonb_array_length(j->'bankLines')>0 and (t<>all(array['sale','receipt']) or coalesce((j->>'supplierRefund')::boolean,false))) then raise exception 'Invalid bank lines'; end if;
    for l in select value from jsonb_array_elements(j->'bankLines') loop
      if jsonb_typeof(l)<>'object' then raise exception 'Invalid bank lines'; end if;
      if exists(select 1 from jsonb_object_keys(l) key where key<>all(array['amount','account','party','bankName'])) or coalesce(jsonb_typeof(l->'amount'),'null')<>'number' or coalesce(l->>'amount','')!~'^[0-9]+$' then raise exception 'Invalid bank lines'; end if;
      if (l->>'amount')::numeric<=0 or (l->>'amount')::numeric>9000000000000 then raise exception 'Invalid bank lines'; end if;
      if (l ? 'account' and jsonb_typeof(l->'account')<>'string') or (l ? 'party' and jsonb_typeof(l->'party')<>'string') or ((coalesce(l->>'account','')<>'')=(coalesce(l->>'party','')<>'')) or (l ? 'bankName' and (jsonb_typeof(l->'bankName')<>'string' or length(l->>'bankName')>120)) then raise exception 'Invalid bank lines'; end if;
      if coalesce(l->>'party','')<>'' then
        if l->>'party'=p or not exists(select 1 from public.khata_records where owner_id=o and id=l->>'party' and kind='party' and not coalesce((data->>'deleted')::boolean,false)) then raise exception 'Choose the party that was paid directly'; end if;
      elsif not exists(select 1 from public.khata_records where owner_id=o and id=l->>'account' and kind='account' and id<>'cash') then raise exception 'Choose a bank account'; end if;
      collected:=collected+(l->>'amount')::bigint;
    end loop;
  end if;
  if t=any(array['payment','expense','purchase','transfer','deposit','depositRefund']) and not exists(select 1 from public.khata_records where owner_id=o and id=a and kind='account') then raise exception 'Choose a money account'; end if;
  if t=any(array['payment','expense','transfer','discount','deposit','depositRefund','historicalSale']) and khata_private.n(j,'amount')<=0 then raise exception 'Enter an amount greater than zero'; end if;
  if t='sale' then
    if (khata_private.n(j->'quantities','11800')+khata_private.n(j->'quantities','15000')+khata_private.n(j->'quantities','45000')+khata_private.n(j,'extraGrams'))<=0 or ((coalesce((j->>'bulkAtCost')::boolean,false)=false or khata_private.n(j->'quantities','11800')+khata_private.n(j->'quantities','15000')+khata_private.n(j->'quantities','45000')>0) and khata_private.n(j,'rate')<=0) then raise exception 'Enter a quantity and rate'; end if;
    if exists(select 1 from public.khata_records where owner_id=o and kind='document' and id<>did and data->>'type'='historicalSale' and data->>'date'=j->>'date' and coalesce((data->>'voided')::boolean,false)=false) then raise exception 'Void the historical summary before adding detailed sales'; end if;
  end if;
  if t='receipt' and collected<=0 then raise exception 'Enter a collection amount'; end if;
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
    if not exists(select 1 from public.khata_records where owner_id=o and id=j->>'sourceInvoice' and kind='document' and data->>'type'='sale' and data->>'party'=p and (data->>'date')::date<=dt and coalesce((data->>'voided')::boolean,false)=false and data->'quantities'=j->'quantities' and khata_private.n(data,'rate')=khata_private.n(j,'rate') and khata_private.n(data,'extraGrams')=khata_private.n(j,'extraGrams') and coalesce((data->>'bulkAtCost')::boolean,false)=coalesce((j->>'bulkAtCost')::boolean,false) and khata_private.n(data,'bulkCost')=khata_private.n(j,'bulkCost')) or exists(select 1 from public.khata_records where owner_id=o and kind='document' and id<>did and data->>'type'='creditNote' and data->>'sourceInvoice'=j->>'sourceInvoice' and coalesce((data->>'voided')::boolean,false)=false) then raise exception 'Choose an invoice without an existing credit note'; end if;
  end if;
  if j ? 'allocations' and jsonb_typeof(j->'allocations')<>'object' then raise exception 'Invalid allocation'; end if;
  if j ? 'allocations' then
    val:=0;
    for k in select jsonb_object_keys(j->'allocations') loop
      if khata_private.n(j->'allocations',k)<0 or not exists(select 1 from public.khata_records where owner_id=o and id=k and kind='document' and data->>'party'=p and data->>'type'='sale' and coalesce((data->>'voided')::boolean,false)=false) then raise exception 'Invalid allocation'; end if;
      val:=val+khata_private.n(j->'allocations',k);
    end loop;
    if val>collected then raise exception 'Allocation exceeds collection'; end if;
  end if;
end$$;

-- Keep the cost recovery for shared purchases outside sales and COGS.
-- The original four-argument function remains available to existing callers.
alter table public.khata_fifo add column if not exists cost_account text not null default 'cogs';
create or replace function khata_private.consume(o uuid,d text,dt date,g bigint,cost_account text) returns bigint
language plpgsql set search_path='' as $$
declare lot record; remaining bigint:=g; used bigint; c bigint;
begin
  for lot in select * from public.khata_lots where owner_id=o and grams>0 order by ordinal loop
    exit when remaining<=0;
    used:=least(remaining,lot.grams);
    if lot.cost is null then c:=null; else c:=khata_private.round_div(lot.cost::numeric*used,lot.grams); perform khata_private.pair(o,d,dt,cost_account,'inventory',c); end if;
    insert into public.khata_fifo(owner_id,sale,lot,grams,cost,cost_account) values(o,d,lot.id,used,c,cost_account);
    update public.khata_lots set grams=grams-used,cost=cost-c where owner_id=o and id=lot.id;
    remaining:=remaining-used;
  end loop;
  if remaining>0 then insert into public.khata_fifo(owner_id,sale,lot,grams,cost,cost_account) values(o,d,null,remaining,null,cost_account); end if;
  return remaining;
end$$;
create or replace function khata_private.consume(o uuid,d text,dt date,g bigint) returns bigint
language plpgsql set search_path='' as $$
declare cost_account text;
begin
  select case when data->>'type'='stockAdjustment' then 'expense:Stock loss' else 'cogs' end into cost_account from public.khata_records where owner_id=o and id=d;
  return khata_private.consume(o,d,dt,g,cost_account);
end$$;
create or replace function khata_private.rebuild(o uuid) returns void
language plpgsql set search_path='' as $$
declare r record; j jsonb; l jsonb; original jsonb; t text; dt date; p text; a text; bank text; dp text; amount bigint; cash bigint; b bigint; direct bigint; g bigint; bill bigint; cyl bigint; extra bigint; unit bigint; cost bigint; seq bigint:=0; size text; issued bigint; returned bigint; shortage bigint:=0; covered bigint; reserved bigint; shared boolean; shared_cost bigint; verified jsonb:=coalesce(nullif(current_setting('khata.verify_shares',true),''),'[]')::jsonb;
begin
  delete from public.khata_postings where owner_id=o;
  delete from public.khata_lots where owner_id=o;
  delete from public.khata_fifo where owner_id=o;
  delete from public.khata_cylinders where owner_id=o;
  for r in select id,data from public.khata_records where owner_id=o and kind='document' and coalesce((data->>'voided')::boolean,false)=false order by data->>'date',khata_private.n(data,'occurredAt'),id loop
    j:=r.data; t:=j->>'type'; dt:=(j->>'date')::date; p:=coalesce(j->>'party',''); a:=coalesce(j->>'account','cash'); bank:=coalesce(j->>'bankAccount',''); amount:=khata_private.n(j,'amount'); cash:=khata_private.n(j,'cash'); b:=khata_private.n(j,'bank'); seq:=seq+1;
    direct:=khata_private.n(j,'direct'); dp:=coalesce(j->>'directParty','');
    case t
    when 'sale' then
      g:=11800*khata_private.n(j->'quantities','11800')+15000*khata_private.n(j->'quantities','15000')+45000*khata_private.n(j->'quantities','45000');
      cyl:=khata_private.round_div(g::numeric*khata_private.n(j,'rate'),1180000)*100;
      shared:=coalesce((j->>'bulkAtCost')::boolean,false); if shared then bill:=cyl+khata_private.n(j,'bulkCost'); extra:=0; else bill:=khata_private.round_div((g+khata_private.n(j,'extraGrams'))::numeric*khata_private.n(j,'rate'),1180000)*100; extra:=bill-cyl; end if;
      perform khata_private.line(o,r.id,dt,'ar:'||p,bill+khata_private.n(j,'depositCharge'));
      perform khata_private.line(o,r.id,dt,'revenue:gas',-cyl); perform khata_private.line(o,r.id,dt,'revenue:bulk',-extra); if shared then perform khata_private.line(o,r.id,dt,'purchase-share:cost',-khata_private.n(j,'bulkCost')); end if; perform khata_private.line(o,r.id,dt,'deposit:'||p,-khata_private.n(j,'depositCharge'));
      perform khata_private.pair(o,r.id,dt,'money:cash','ar:'||p,cash); perform khata_private.pair(o,r.id,dt,'money:'||bank,'ar:'||p,b);
      perform khata_private.pair(o,r.id,dt,'ap:'||dp,'ar:'||p,direct);
      if jsonb_typeof(j->'bankLines')='array' then
        for l in select value from jsonb_array_elements(j->'bankLines') loop
          if coalesce(l->>'party','')<>'' then
            perform khata_private.pair(o,r.id,dt,'ap:'||(l->>'party'),'ar:'||p,khata_private.n(l,'amount'));
          else
            perform khata_private.pair(o,r.id,dt,'money:'||(l->>'account'),(case when t='receipt' and coalesce((j->>'supplierRefund')::boolean,false) then 'ap:' else 'ar:' end)||p,khata_private.n(l,'amount'));
          end if;
        end loop;
      end if;
      if shared then
        shortage:=shortage+khata_private.consume(o,r.id,dt,g);
        shortage:=shortage+khata_private.consume(o,r.id,dt,khata_private.n(j,'extraGrams'),'purchase-share:cost');
        if exists(select 1 from public.khata_fifo f where f.owner_id=o and f.sale=r.id and f.cost_account='purchase-share:cost' and f.cost is null) then raise exception 'Enter dated stock and purchase cost before sharing gas'; end if;
        select coalesce(sum(f.cost),0) into shared_cost from public.khata_fifo f where f.owner_id=o and f.sale=r.id and f.cost_account='purchase-share:cost';
        if verified ? r.id and shared_cost<>khata_private.n(j,'bulkCost') then raise exception 'Purchase-share cost changed; refresh the entry'; end if;
      else
        shortage:=shortage+khata_private.consume(o,r.id,dt,g+khata_private.n(j,'extraGrams'));
      end if;
      if coalesce((j->>'customerOwned')::boolean,false)=false then
        foreach size in array array['11800','15000','45000'] loop
          issued:=khata_private.n(j->'quantities',size); returned:=khata_private.n(j->'returned',size);
          perform khata_private.cylinder(o,size,-issued,returned,0); perform khata_private.cylinder(o,p||':'||size,0,0,issued-returned);
        end loop;
      end if;
    when 'receipt' then
      a:=case when coalesce((j->>'supplierRefund')::boolean,false) then 'ap:' else 'ar:' end||p;
      perform khata_private.pair(o,r.id,dt,'money:cash',a,cash); perform khata_private.pair(o,r.id,dt,'money:'||bank,a,b);
      perform khata_private.pair(o,r.id,dt,'ap:'||dp,'ar:'||p,direct);
      if jsonb_typeof(j->'bankLines')='array' then
        for l in select value from jsonb_array_elements(j->'bankLines') loop
          if coalesce(l->>'party','')<>'' then
            perform khata_private.pair(o,r.id,dt,'ap:'||(l->>'party'),'ar:'||p,khata_private.n(l,'amount'));
          else
            perform khata_private.pair(o,r.id,dt,'money:'||(l->>'account'),(case when t='receipt' and coalesce((j->>'supplierRefund')::boolean,false) then 'ap:' else 'ar:' end)||p,khata_private.n(l,'amount'));
          end if;
        end loop;
      end if;
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
      shared:=coalesce((original->>'bulkAtCost')::boolean,false); if shared then bill:=cyl+khata_private.n(original,'bulkCost'); else bill:=khata_private.round_div((g+khata_private.n(original,'extraGrams'))::numeric*khata_private.n(original,'rate'),1180000)*100; end if;
      perform khata_private.line(o,r.id,dt,'revenue:gas',cyl); if shared then perform khata_private.line(o,r.id,dt,'purchase-share:cost',khata_private.n(original,'bulkCost')); else perform khata_private.line(o,r.id,dt,'revenue:bulk',bill-cyl); end if; perform khata_private.line(o,r.id,dt,'ar:'||p,-bill);
      g:=g+khata_private.n(original,'extraGrams');
      if coalesce((j->>'stockReturned')::boolean,false) and g>0 then
        if exists(select 1 from public.khata_fifo f where f.owner_id=o and f.sale=j->>'sourceInvoice' and f.cost is null) then raise exception 'Record the missing purchase cost before returning stock'; end if;
        select coalesce(sum(f.cost),0),coalesce(sum(f.cost) filter(where f.cost_account='purchase-share:cost'),0) into cost,shared_cost from public.khata_fifo f where f.owner_id=o and f.sale=j->>'sourceInvoice';
        perform khata_private.pair(o,r.id,dt,'inventory','cogs',cost-shared_cost);
        perform khata_private.pair(o,r.id,dt,'inventory','purchase-share:cost',shared_cost);
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
        if exists(select 1 from public.khata_records where owner_id=o and kind='document' and (data->>'party'=ident or (data->>'directParty'=ident and khata_private.n(data,'direct')>0) or exists(select 1 from jsonb_array_elements(case when jsonb_typeof(data->'bankLines')='array' then data->'bankLines' else '[]'::jsonb end) l where l->>'party'=ident)) and coalesce((data->>'voided')::boolean,false)=false) then raise exception 'This party has entries and cannot be deleted'; end if;
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
    if financial then
      perform set_config('khata.verify_shares',to_jsonb(changed)::text,true);
      perform khata_private.rebuild(o);
    end if;
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

revoke all on all functions in schema khata_private from public,anon,authenticated;

-- Rebuild caches without repricing recorded party charges.
do $$ declare o uuid; begin
  for o in select owner_id from public.khata_sync for update loop
    perform khata_private.rebuild(o);
  end loop;
end$$;
