-- Sales entered before their purchase: the gas they took without stock waits
-- (a FIFO row with no lot) and the next stock covers it first, oldest first,
-- at that lot's cost. The cost is posted under the waiting document itself
-- (dated the day the stock came, so closed days never change), instead of
-- one provisional 'cogs:shortage' on the purchase. A physical return of an
-- invoice cancels its gas that is still waiting. A financial-only credit note
-- of a purchase share turns the shared gas's cost into cost of gas sold.
-- A purchase share without stock waits like any sale; only the shares being
-- saved in this command must end up fully covered at their recorded price,
-- checked after the whole replay. Mirrors Book._stockOut/_stockIn in Dart.

-- Insertion order of FIFO rows: waiting rows are covered in this order.
alter table public.khata_fifo add column if not exists ordinal bigserial;

create or replace function khata_private.stock_in(o uuid,d text,seq bigint,dt date,g bigint,c bigint) returns void
language plpgsql set search_path='' as $$
declare lot_grams bigint:=g; lot_cost bigint:=c; f record; used bigint; part bigint;
begin
  for f in select * from public.khata_fifo where owner_id=o and lot is null order by ordinal loop
    exit when lot_grams<=0;
    used:=least(f.grams,lot_grams);
    part:=case when lot_cost is null then null else khata_private.round_div(lot_cost::numeric*used,lot_grams) end;
    if part is not null then perform khata_private.pair(o,f.sale,dt,f.cost_account,'inventory',part); end if;
    if used=f.grams then delete from public.khata_fifo where owner_id=o and ordinal=f.ordinal;
    else update public.khata_fifo set grams=grams-used where owner_id=o and ordinal=f.ordinal; end if;
    insert into public.khata_fifo(owner_id,sale,lot,grams,cost,cost_account) values(o,f.sale,d,used,part,f.cost_account);
    lot_grams:=lot_grams-used; lot_cost:=lot_cost-part;
  end loop;
  insert into public.khata_lots values(o,d,seq,dt,lot_grams,lot_cost);
end$$;

create or replace function khata_private.rebuild(o uuid) returns void
language plpgsql set search_path='' as $$
declare r record; j jsonb; l jsonb; original jsonb; t text; dt date; p text; a text; bank text; dp text; amount bigint; cash bigint; b bigint; direct bigint; g bigint; bill bigint; cyl bigint; extra bigint; unit bigint; cost bigint; seq bigint:=0; size text; issued bigint; returned bigint; shared boolean; shared_cost bigint; pending bigint; verified jsonb:=coalesce(nullif(current_setting('khata.verify_shares',true),''),'[]')::jsonb;
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
        perform khata_private.consume(o,r.id,dt,g);
        perform khata_private.consume(o,r.id,dt,khata_private.n(j,'extraGrams'),'purchase-share:cost');
      else
        perform khata_private.consume(o,r.id,dt,g+khata_private.n(j,'extraGrams'));
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
      perform khata_private.stock_in(o,r.id,seq,dt,g,cost);
    when 'transfer' then perform khata_private.pair(o,r.id,dt,'money:'||(j->>'toAccount'),'money:'||a,amount);
    when 'discount' then perform khata_private.pair(o,r.id,dt,'expense:Write-off','ar:'||p,amount);
    when 'adjustment' then perform khata_private.pair(o,r.id,dt,j->>'target','equity:opening',amount);
    when 'stockAdjustment' then
      g:=khata_private.n(j,'grams');
      if g>0 then
        cost:=case when coalesce((j->>'costKnown')::boolean,false) then khata_private.n(j,'cost') else null end;
        perform khata_private.stock_in(o,r.id,seq,dt,g,cost);
        if cost is not null then perform khata_private.pair(o,r.id,dt,'inventory','equity:opening',cost); end if;
      else perform khata_private.consume(o,r.id,dt,-g); end if;
    when 'cylinder' then
      size:=khata_private.n(j,'size')::text; perform khata_private.cylinder(o,size,khata_private.n(j,'fullDelta'),khata_private.n(j,'emptyDelta'),0);
      if p<>'' then perform khata_private.cylinder(o,p||':'||size,0,0,khata_private.n(j,'heldDelta')); end if;
    when 'deposit' then perform khata_private.pair(o,r.id,dt,'money:'||a,'deposit:'||p,amount);
    when 'depositRefund' then perform khata_private.pair(o,r.id,dt,'deposit:'||p,'money:'||a,amount);
    when 'historicalSale' then perform khata_private.consume(o,r.id,dt,khata_private.n(j,'grams'));
    when 'creditNote' then
      select data into original from public.khata_records where owner_id=o and id=j->>'sourceInvoice' and kind='document' and coalesce((data->>'voided')::boolean,false)=false;
      if original is null then raise exception 'Void the related credit note first'; end if;
      g:=11800*khata_private.n(original->'quantities','11800')+15000*khata_private.n(original->'quantities','15000')+45000*khata_private.n(original->'quantities','45000');
      cyl:=khata_private.round_div(g::numeric*khata_private.n(original,'rate'),1180000)*100;
      shared:=coalesce((original->>'bulkAtCost')::boolean,false); if shared then bill:=cyl+khata_private.n(original,'bulkCost'); else bill:=khata_private.round_div((g+khata_private.n(original,'extraGrams'))::numeric*khata_private.n(original,'rate'),1180000)*100; end if;
      perform khata_private.line(o,r.id,dt,'revenue:gas',cyl); if shared then perform khata_private.line(o,r.id,dt,'purchase-share:cost',khata_private.n(original,'bulkCost')); else perform khata_private.line(o,r.id,dt,'revenue:bulk',bill-cyl); end if; perform khata_private.line(o,r.id,dt,'ar:'||p,-bill);
      g:=g+khata_private.n(original,'extraGrams');
      if coalesce((j->>'stockReturned')::boolean,false) and g>0 then
        -- Gas still waiting for stock comes back before any stock covered it.
        with cancelled as (delete from public.khata_fifo f where f.owner_id=o and f.sale=j->>'sourceInvoice' and f.lot is null returning f.grams)
        select coalesce(sum(grams),0) into pending from cancelled;
        if exists(select 1 from public.khata_fifo f where f.owner_id=o and f.sale=j->>'sourceInvoice' and f.cost is null) then raise exception 'Record the missing purchase cost before returning stock'; end if;
        select coalesce(sum(f.cost),0),coalesce(sum(f.cost) filter(where f.cost_account='purchase-share:cost'),0) into cost,shared_cost from public.khata_fifo f where f.owner_id=o and f.sale=j->>'sourceInvoice';
        perform khata_private.pair(o,r.id,dt,'inventory','cogs',cost-shared_cost);
        perform khata_private.pair(o,r.id,dt,'inventory','purchase-share:cost',shared_cost);
        if g>pending then perform khata_private.stock_in(o,r.id,seq,dt,g-pending,cost); end if;
      elsif shared and not coalesce((j->>'stockReturned')::boolean,false) then
        -- The charge is cancelled but the shared gas is gone: cost of gas sold.
        select coalesce(sum(f.cost),0) into shared_cost from public.khata_fifo f where f.owner_id=o and f.sale=j->>'sourceInvoice' and f.cost_account='purchase-share:cost';
        perform khata_private.pair(o,r.id,dt,'cogs','purchase-share:cost',shared_cost);
      end if;
    else raise exception 'Unknown entry type';
    end case;
  end loop;
  -- Shares saved by this command: covered by stock of known cost (possibly a
  -- later purchase) and charged exactly that FIFO cost.
  for r in select id,data from public.khata_records where owner_id=o and kind='document' and id in (select jsonb_array_elements_text(verified)) and data->>'type'='sale' and coalesce((data->>'bulkAtCost')::boolean,false) and coalesce((data->>'voided')::boolean,false)=false order by data->>'date',khata_private.n(data,'occurredAt'),id loop
    if exists(select 1 from public.khata_fifo f where f.owner_id=o and f.sale=r.id and f.cost_account='purchase-share:cost' and f.cost is null) then raise exception 'Enter dated stock and purchase cost before sharing gas'; end if;
    select coalesce(sum(f.cost),0) into shared_cost from public.khata_fifo f where f.owner_id=o and f.sale=r.id and f.cost_account='purchase-share:cost';
    if shared_cost<>khata_private.n(r.data,'bulkCost') then raise exception 'Purchase-share cost changed; refresh the entry'; end if;
  end loop;
  if exists(select 1 from public.khata_postings where owner_id=o group by document_id having sum(debit)<>0) then raise exception 'Unbalanced accounting document'; end if;
  if exists(select 1 from public.khata_cylinders where owner_id=o and held_count<0) then raise exception 'Cylinder returns exceed this party’s outstanding cylinders'; end if;
  if exists(select 1 from public.khata_postings where owner_id=o and account like 'deposit:%' group by account having sum(debit)>0) then raise exception 'Refund exceeds the refundable deposit'; end if;
end$$;

revoke all on all functions in schema khata_private from public,anon,authenticated;

-- Recalculate existing owners' derived caches with the new rule. Source
-- documents, recorded prices and the sync sequence are unchanged.
do $$ declare o uuid; begin
  for o in select owner_id from public.khata_sync for update loop
    perform khata_private.rebuild(o);
  end loop;
end$$;
