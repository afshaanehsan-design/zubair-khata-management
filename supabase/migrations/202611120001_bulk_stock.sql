-- Both cylinder gas and bulk KG consume FIFO stock. Billing, collections
-- and cylinder custody retain their existing behavior. Full physical returns
-- restore the entire invoice quantity and its original FIFO cost.
create or replace function khata_private.rebuild(o uuid) returns void
language plpgsql set search_path='' as $$
declare r record; j jsonb; l jsonb; original jsonb; t text; dt date; p text; a text; bank text; dp text; amount bigint; cash bigint; b bigint; direct bigint; g bigint; bill bigint; cyl bigint; extra bigint; unit bigint; cost bigint; seq bigint:=0; size text; issued bigint; returned bigint; shortage bigint:=0; covered bigint; reserved bigint;
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
      bill:=khata_private.round_div((g+khata_private.n(j,'extraGrams'))::numeric*khata_private.n(j,'rate'),1180000)*100; extra:=bill-cyl;
      perform khata_private.line(o,r.id,dt,'ar:'||p,bill+khata_private.n(j,'depositCharge'));
      perform khata_private.line(o,r.id,dt,'revenue:gas',-cyl); perform khata_private.line(o,r.id,dt,'revenue:bulk',-extra); perform khata_private.line(o,r.id,dt,'deposit:'||p,-khata_private.n(j,'depositCharge'));
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
      shortage:=shortage+khata_private.consume(o,r.id,dt,g+khata_private.n(j,'extraGrams'));
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
      bill:=khata_private.round_div((g+khata_private.n(original,'extraGrams'))::numeric*khata_private.n(original,'rate'),1180000)*100;
      perform khata_private.line(o,r.id,dt,'revenue:gas',cyl); perform khata_private.line(o,r.id,dt,'revenue:bulk',bill-cyl); perform khata_private.line(o,r.id,dt,'ar:'||p,-bill);
      g:=g+khata_private.n(original,'extraGrams');
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

-- Caches are derived from documents. Reproject existing owners so past bulk
-- sales and physical returns use the same stock rule as newly posted sales.
do $$ declare o uuid; begin
  for o in select owner_id from public.khata_sync for update loop
    perform khata_private.rebuild(o);
  end loop;
end$$;
