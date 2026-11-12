-- Keep the Roznamcha form an entry was made in ("form", display only) and
-- the parchi / van number on cash-only Aamad receipts ("vehicle").
-- Accounting and validation are unchanged.
create or replace function khata_private.canonical_document(j jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare common text[]:=array['type','date','occurredAt','party','note','reference','voided','voidReason','replacement','replaces','restoredFrom','form']; fields text[];
begin
  fields:=case j->>'type'
    when 'sale' then array['quantities','returned','rate','extraGrams','depositCharge','cash','bank','bankAccount','customerOwned','vehicle','dueDate','allocations']
    when 'receipt' then array['cash','bank','bankAccount','supplierRefund','allocations','vehicle']
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
