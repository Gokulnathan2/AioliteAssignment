import 'package:hive/hive.dart';

import '../models/queued_action.dart';
import '../sync/sync_logger.dart';

/// Signature for a backend apply operation.
abstract class RemoteActionApplier {
  Future<void> applyAction(QueuedAction action);
}

class OfflineSyncQueue {
  OfflineSyncQueue({
    required this.queueBox,
    required this.metaBox,
    required this.logger,
    required this.applier,
    this.backoffMillis = 500,
    this.maxRetries = 1,
  });

  final Box<String> queueBox;
  final Box<String> metaBox;
  final SyncLogger logger;
  final RemoteActionApplier applier;

  /// Base delay between attempt 1 failure and attempt 2 attempt.
  final int backoffMillis;

  /// Max number of retries after the first attempt.
  /// Example: `maxRetries = 1` => at most 2 total attempts.
  final int maxRetries;

  static const String metaSyncSuccessCountKey = 'syncSuccessCount';
  static const String metaSyncFailCountKey = 'syncFailCount';

  int get _successCount => int.tryParse(metaBox.get(metaSyncSuccessCountKey) ?? '')
      ?? 0;
  int get _failCount => int.tryParse(metaBox.get(metaSyncFailCountKey) ?? '')
      ?? 0;

  Future<int> pendingQueueSize() async {
    var count = 0;
    for (final key in queueBox.keys) {
      final json = queueBox.get(key);
      if (json == null) continue;
      final action = QueuedAction.fromJsonString(json);
      if (!action.permanentlyFailed) count++;
    }
    return count;
  }

  Future<void> enqueue(QueuedAction action) async {
    final existing = queueBox.get(action.actionId);
    if (existing != null) {
      logger.info(
        'QUEUE_ENQUEUE_DEDUP actionId=${action.actionId} already exists; pendingQueueSize=${await pendingQueueSize()}',
      );
      return;
    }

    await queueBox.put(action.actionId, action.toJsonString());
    logger.info(
      'QUEUE_ENQUEUE actionId=${action.actionId} type=${action.type} pendingQueueSize=${await pendingQueueSize()}',
    );
  }

  Future<void> syncDueActions() async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;

    // Read all due actions deterministically
    final dueActions = <QueuedAction>[];
    for (final key in queueBox.keys) {
      final json = queueBox.get(key);
      if (json == null) continue;
      final action = QueuedAction.fromJsonString(json);
      if (action.permanentlyFailed) continue;
      if (action.nextAttemptAtMillis <= nowMillis) {
        dueActions.add(action);
      }
    }
    dueActions.sort((a, b) => a.createdAtMillis.compareTo(b.createdAtMillis));

    if (dueActions.isEmpty) {
      logger.info('SYNC_DUE_EMPTY pendingQueueSize=${await pendingQueueSize()}');
      return;
    }

    for (final action in dueActions) {
      logger.info(
        'SYNC_ATTEMPT actionId=${action.actionId} type=${action.type} attempts=${action.attempts} pendingQueueSize=${await pendingQueueSize()}',
      );
      try {
        await applier.applyAction(action);
        await queueBox.delete(action.actionId);

        final newSuccess = _successCount + 1;
        await metaBox.put(metaSyncSuccessCountKey, newSuccess.toString());

        logger.info(
          'SYNC_SUCCESS actionId=${action.actionId} pendingQueueSize=${await pendingQueueSize()} syncSuccess=$_successCount',
        );
      } catch (e) {
        final errorMessage = e.toString();
        final shouldRetry = action.attempts < maxRetries;

        if (shouldRetry) {
          final nextAttempts = action.attempts + 1;
          final backoffMultiplier = 1 << (nextAttempts - 1); // basic exponential backoff
          final nextAttemptAtMillis = nowMillis + (backoffMillis * backoffMultiplier);

          final updated = action.copyWith(
            attempts: nextAttempts,
            nextAttemptAtMillis: nextAttemptAtMillis,
            lastError: errorMessage,
          );
          await queueBox.put(action.actionId, updated.toJsonString());

          final newFail = _failCount + 1;
          await metaBox.put(metaSyncFailCountKey, newFail.toString());

          logger.info(
            'SYNC_FAIL_RETRY_SCHEDULE actionId=${action.actionId} attempts=${updated.attempts} nextAttemptAtMillis=$nextAttemptAtMillis pendingQueueSize=${await pendingQueueSize()} syncFail=$_failCount error=$errorMessage',
          );
        } else {
          final updated = action.copyWith(
            permanentlyFailed: true,
            lastError: errorMessage,
          );
          await queueBox.put(action.actionId, updated.toJsonString());

          final newFail = _failCount + 1;
          await metaBox.put(metaSyncFailCountKey, newFail.toString());

          logger.info(
            'SYNC_FAIL_PERMANENT actionId=${action.actionId} pendingQueueSize=${await pendingQueueSize()} syncFail=$_failCount error=$errorMessage',
          );
        }
      }
    }
  }
}

