-- lookup_command was never called by the app. A command that was sent but
-- never confirmed is simply sent again: apply_command answers a repeat of the
-- same command id and payload from its receipt (khata_receipts), so a client
-- has nothing to look up. This removes the unused RPC. No data changes.
drop function if exists public.lookup_command(uuid);
