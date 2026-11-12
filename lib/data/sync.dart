import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/models.dart';
import 'database.dart';

abstract interface class SyncTransport {
  Future<Json> status();
  Future<List<Json>> pull(String epoch, int after);
  Future<Json> apply(Command command);

  /// Erases the owner's whole cloud dataset and rotates its epoch, so every
  /// other device stops writing until it reconnects. Returns the new status.
  Future<Json> reset(String epoch);
}

class SupabaseTransport implements SyncTransport {
  final SupabaseClient client;
  SupabaseTransport(this.client);
  @override
  Future<Json> status() async =>
      Map<String, dynamic>.from(await client.rpc('sync_status') as Map);
  @override
  Future<List<Json>> pull(String epoch, int after) async => (await client.rpc(
    'pull_changes',
    params: {'p_epoch': epoch, 'p_after': after, 'p_limit': 100},
  ) as List).map((v) => Map<String, dynamic>.from(v as Map)).toList();
  @override
  Future<Json> apply(Command command) async => Map<String, dynamic>.from(
    await client.rpc('apply_command', params: {'p_command': command.payload})
        as Map,
  );
  @override
  Future<Json> reset(String epoch) async => Map<String, dynamic>.from(
    await client.rpc('reset_dataset', params: {'p_epoch': epoch}) as Map,
  );
}

class SyncService {
  final KhataDatabase db;
  final SyncTransport transport;
  final void Function() changed;
  bool running = false;
  String message = 'Offline';
  int failures = 0;
  Timer? _retry;
  bool disposed = false;
  SyncService(this.db, this.transport, this.changed);

  Future<void> _pull(String epoch) async {
    while (true) {
      final cursor = integer(await db.meta('cursor'));
      final page = await transport.pull(epoch, cursor);
      if (page.isEmpty) break;
      await db.applyBundles(page, integer(page.last['sequence']));
      if (page.length < 100) break;
    }
  }

  Future<void>? _active;

  /// Completes when the synchronization in progress (if any) has finished.
  /// The database must not be closed before that.
  Future<void> get idle => _active ?? Future<void>.value();

  Future<void> synchronize() {
    if (running || disposed) return Future<void>.value();
    return _active = _synchronize();
  }

  Future<void> _synchronize() async {
    running = true;
    message = 'Syncing';
    changed();
    try {
      final state = await transport.status();
      if (integer(state['protocol']) != 1) {
        throw StateError('Update the app to synchronize');
      }
      final serverEpoch = '${state['epoch']}';
      final localEpoch = await db.meta('epoch');
      if (localEpoch != null && localEpoch != serverEpoch) {
        throw StateError(
          'Cloud recovery detected. Preserve a backup and reconnect this dataset.',
        );
      }
      await db.setMeta('epoch', serverEpoch);
      await _pull(serverEpoch);
      for (var command in await db.commands()) {
        if (!['queued', 'sending', 'accepted'].contains(command.status)) {
          continue;
        }
        // Bind never-transmitted offline commands once; frozen retries keep identical payloads.
        if (command.epoch == '' && command.status == 'queued') {
          command = Command(
            id: command.id,
            device: command.device,
            epoch: serverEpoch,
            action: command.action,
            changes: command.changes,
            reason: command.reason,
            created: command.created,
          );
          await db.customStatement('UPDATE commands SET payload=? WHERE id=?', [
            jsonEncode(command.payload),
            command.id,
          ]);
        }
        await db.commandState(command.id, 'sending');
        final result = await transport.apply(command);
        final status = '${result['status']}';
        if (status == 'accepted') {
          await db.commandState(command.id, 'accepted');
        } else {
          await db.commandState(
            command.id,
            status == 'conflict' ? 'conflict' : 'rejected',
            '${result['message'] ?? 'Review this change'}',
          );
        }
        await _pull(serverEpoch);
      }
      failures = 0;
      message = 'Up to date';
    } catch (e) {
      failures++;
      message = 'Sync paused: $e';
      _retry?.cancel();
      if (!disposed) {
        _retry = Timer(
          Duration(seconds: (5 * (1 << failures.clamp(0, 6))).clamp(5, 300)),
          () {
            unawaited(synchronize());
          },
        );
      }
    } finally {
      running = false;
      if (!disposed) changed();
    }
  }

  void dispose() {
    disposed = true;
    _retry?.cancel();
  }
}
