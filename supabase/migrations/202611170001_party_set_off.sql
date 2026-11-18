-- A party's two sides are set off against each other (asked for by the user
-- on 17 November 2026). A party can be owed money by you on its receivable
-- side (`ar:`, sales and collections) and be owed by you on its payable side
-- (`ap:`, purchases and payments to it), e.g. a customer you also buy gas
-- from. After every document, in document order, a party whose two sides
-- point opposite ways has the smaller set off against the larger: postings
-- under that document, on its date, that move the amount from one side to
-- the other. The khata balance (`ar:` + `ap:`) never changes; only one side
-- is left, so a purchase from a customer who owes you lowers what he owes.
-- Mirrors Book._setOff in Dart. Documents, recorded prices and the sync
-- sequence are unchanged; only the derived postings are rebuilt.

create or replace function khata_private.rebuild(o uuid) returns void
language plpgsql set search_path='' as $$
declare r record; j jsonb; l jsonb; original jsonb; t text; dt date; p text; a text; bank text; dp text; amount bigint; cash bigint; b bigint; direct bigint; g bigint; bill bigint; cyl bigint; extra bigint; unit bigint; cost bigint; seq bigint:=0; size text; issued bigint; returned bigint; shared boolean; shared_cost bigint; pending bigint; pr record; waiting record; res jsonb; taken jsonb:='{}'; reserve jsonb:='{}'; used bigint; granted bigint; reserved bigint; reserved_cost bigint; verified jsonb:=coalesce(nullif(current_setting('khata.verify_shares',true),''),'[]')::jsonb; sides jsonb:='{}'; ar_bal bigint; ap_bal bigint; m bigint;
begin
  delete from public.khata_postings where owner_id=o;
  delete from public.khata_lots where owner_id=o;
  delete from public.khata_fifo where owner_id=o;
  delete from public.khata_cylinders where owner_id=o;
  -- Shares from a chosen purchase (Book._reserveShares): in document order each
  -- reserves its KG from the live purchase with that reference, up to what is
  -- left; that gas never enters FIFO stock. Its cost is the purchase bill split
  -- by KG on the running total; its charge is the purchase rate for its KG.
  -- A share whose gas a physical credit note returned reserves nothing.
  for r in select s.id,s.data,exists(select 1 from public.khata_records c where c.owner_id=o and c.kind='document' and coalesce((c.data->>'voided')::boolean,false)=false and c.data->>'type'='creditNote' and c.data->>'sourceInvoice'=s.id and coalesce((c.data->>'stockReturned')::boolean,false)) returned from public.khata_records s where s.owner_id=o and s.kind='document' and coalesce((s.data->>'voided')::boolean,false)=false and s.data->>'type'='sale' and coalesce((s.data->>'bulkAtCost')::boolean,false) and jsonb_typeof(s.data->'sharePurchase')='string' and s.data->>'sharePurchase'<>'' order by s.data->>'date',khata_private.n(s.data,'occurredAt'),s.id loop
    select p.id,p.data into pr from public.khata_records p where p.owner_id=o and p.kind='document' and coalesce((p.data->>'voided')::boolean,false)=false and p.data->>'type'='purchase' and p.data->>'reference'=r.data->>'sharePurchase' order by p.data->>'date',khata_private.n(p.data,'occurredAt'),p.id limit 1;
    if not found then continue; end if;
    unit:=khata_private.n(pr.data,'rateUnit'); if unit=0 then unit:=11800; end if;
    if r.returned then
      reserve:=reserve||jsonb_build_object(r.id,jsonb_build_object('purchase',pr.id,'grams',0,'cost',0,'excess',0,'charge',khata_private.round_div(khata_private.n(r.data,'extraGrams')::numeric*khata_private.n(pr.data,'rate'),unit*100)*100));
      continue;
    end if;
    g:=khata_private.n(pr.data,'grams'); used:=coalesce((taken->>pr.id)::bigint,0);
    granted:=least(khata_private.n(r.data,'extraGrams'),greatest(g-used,0));
    cost:=khata_private.round_div(g::numeric*khata_private.n(pr.data,'rate'),unit*100)*100;
    taken:=taken||jsonb_build_object(pr.id,used+granted);
    reserve:=reserve||jsonb_build_object(r.id,jsonb_build_object('purchase',pr.id,'grams',granted,'cost',khata_private.round_div(cost::numeric*(used+granted),g)-khata_private.round_div(cost::numeric*used,g),'excess',khata_private.n(r.data,'extraGrams')-granted,'charge',khata_private.round_div(khata_private.n(r.data,'extraGrams')::numeric*khata_private.n(pr.data,'rate'),unit*100)*100));
  end loop;
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
        res:=reserve->r.id; reserved:=coalesce((res->>'grams')::bigint,0);
        if reserved>0 then
          if exists(select 1 from public.khata_lots where owner_id=o and id=res->>'purchase') then
            insert into public.khata_fifo(owner_id,sale,lot,grams,cost,cost_account) values(o,r.id,res->>'purchase',reserved,(res->>'cost')::bigint,'purchase-share:cost');
            perform khata_private.pair(o,r.id,dt,'purchase-share:cost','inventory',(res->>'cost')::bigint);
          else
            -- Its purchase comes later: the reserved gas waits for it.
            insert into public.khata_fifo(owner_id,sale,lot,grams,cost,cost_account) values(o,r.id,res->>'purchase',reserved,null,'purchase-share:cost');
          end if;
        end if;
        perform khata_private.consume(o,r.id,dt,khata_private.n(j,'extraGrams')-reserved,'purchase-share:cost');
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
      -- KG reserved by shares from this purchase never become our stock.
      select coalesce(sum((value->>'grams')::bigint),0),coalesce(sum((value->>'cost')::bigint),0) into reserved,reserved_cost from jsonb_each(reserve) where value->>'purchase'=r.id;
      perform khata_private.stock_in(o,r.id,seq,dt,g-reserved,cost-reserved_cost);
      for waiting in select w.sale,w.ordinal from public.khata_fifo w where w.owner_id=o and w.lot=r.id and w.cost is null and w.cost_account='purchase-share:cost' order by w.ordinal loop
        update public.khata_fifo set cost=(reserve->waiting.sale->>'cost')::bigint where owner_id=o and ordinal=waiting.ordinal;
        perform khata_private.pair(o,waiting.sale,dt,'purchase-share:cost','inventory',(reserve->waiting.sale->>'cost')::bigint);
      end loop;
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
  -- Set-off (Book._setOff): each document's movement on each party's two
  -- sides, in document order. When the sides then point opposite ways, the
  -- smaller is set off against the larger under that document.
  for r in
    select q.doc,q.side_party,(rec.data->>'date')::date doc_date,q.ar_move,q.ap_move
    from (select document_id doc,substr(account,4) side_party,
                 coalesce(sum(debit) filter(where left(account,3)='ar:'),0) ar_move,
                 coalesce(sum(debit) filter(where left(account,3)='ap:'),0) ap_move
          from public.khata_postings where owner_id=o and left(account,3) in ('ar:','ap:')
          group by document_id,substr(account,4)) q
    join public.khata_records rec on rec.owner_id=o and rec.id=q.doc and rec.kind='document'
    order by rec.data->>'date',khata_private.n(rec.data,'occurredAt'),rec.id,q.side_party
  loop
    ar_bal:=coalesce((sides->r.side_party->>0)::bigint,0)+r.ar_move;
    ap_bal:=coalesce((sides->r.side_party->>1)::bigint,0)+r.ap_move;
    m:=case when ar_bal>0 and ap_bal<0 then least(ar_bal,-ap_bal) when ar_bal<0 and ap_bal>0 then -least(-ar_bal,ap_bal) else 0 end;
    if m<>0 then
      perform khata_private.pair(o,r.doc,r.doc_date,'ap:'||r.side_party,'ar:'||r.side_party,m);
      ar_bal:=ar_bal-m; ap_bal:=ap_bal+m;
    end if;
    sides:=sides||jsonb_build_object(r.side_party,jsonb_build_array(ar_bal,ap_bal));
  end loop;
  -- Documents saved by this command (Book's verifyShares): a share must be
  -- fully covered and charged exactly its charge; a purchase must not leave
  -- its shares short, nor be removed while shares still come from it.
  for r in select id,data from public.khata_records where owner_id=o and kind='document' and id in (select jsonb_array_elements_text(verified)) order by data->>'date',khata_private.n(data,'occurredAt'),id loop
    if coalesce((r.data->>'voided')::boolean,false) then
      if r.data->>'type'='purchase' and coalesce(r.data->>'reference','')<>'' and not exists(select 1 from public.khata_records p where p.owner_id=o and p.kind='document' and coalesce((p.data->>'voided')::boolean,false)=false and p.data->>'type'='purchase' and p.data->>'reference'=r.data->>'reference') and exists(select 1 from public.khata_records s where s.owner_id=o and s.kind='document' and coalesce((s.data->>'voided')::boolean,false)=false and s.data->>'type'='sale' and coalesce((s.data->>'bulkAtCost')::boolean,false) and jsonb_typeof(s.data->'sharePurchase')='string' and s.data->>'sharePurchase'=r.data->>'reference' and not exists(select 1 from public.khata_records c where c.owner_id=o and c.kind='document' and coalesce((c.data->>'voided')::boolean,false)=false and c.data->>'type'='creditNote' and c.data->>'sourceInvoice'=s.id and coalesce((c.data->>'stockReturned')::boolean,false))) then raise exception 'Change the shares of this purchase first'; end if;
      continue;
    end if;
    if r.data->>'type'='purchase' then
      if exists(select 1 from jsonb_each(reserve) where value->>'purchase'=r.id and (value->>'excess')::bigint>0) then raise exception 'Shared KG exceed the selected purchase'; end if;
    elsif r.data->>'type'='sale' and coalesce((r.data->>'bulkAtCost')::boolean,false) then
      if jsonb_typeof(r.data->'sharePurchase')='string' and r.data->>'sharePurchase'<>'' then
        res:=reserve->r.id;
        if res is null then raise exception 'Choose a purchase to share from'; end if;
        if (res->>'excess')::bigint>0 then raise exception 'Shared KG exceed the selected purchase'; end if;
        if khata_private.n(r.data,'bulkCost')<>(res->>'charge')::bigint then raise exception 'Purchase-share cost changed; refresh the entry'; end if;
      else
        if exists(select 1 from public.khata_fifo f where f.owner_id=o and f.sale=r.id and f.cost_account='purchase-share:cost' and f.cost is null) then raise exception 'Enter dated stock and purchase cost before sharing gas'; end if;
        select coalesce(sum(f.cost),0) into shared_cost from public.khata_fifo f where f.owner_id=o and f.sale=r.id and f.cost_account='purchase-share:cost';
        if khata_private.n(r.data,'bulkCost')<>khata_private.round_div(shared_cost,100)*100 then raise exception 'Purchase-share cost changed; refresh the entry'; end if;
      end if;
    end if;
  end loop;
  if exists(select 1 from public.khata_postings where owner_id=o group by document_id having sum(debit)<>0) then raise exception 'Unbalanced accounting document'; end if;
  if exists(select 1 from public.khata_cylinders where owner_id=o and held_count<0) then raise exception 'Cylinder returns exceed this party’s outstanding cylinders'; end if;
  if exists(select 1 from public.khata_postings where owner_id=o and account like 'deposit:%' group by account having sum(debit)>0) then raise exception 'Refund exceeds the refundable deposit'; end if;
end$$;

revoke all on all functions in schema khata_private from public,anon,authenticated;

-- Recalculate existing owners' derived caches with the set-off.
do $$ declare o uuid; begin
  for o in select owner_id from public.khata_sync for update loop
    perform khata_private.rebuild(o);
  end loop;
end$$;
