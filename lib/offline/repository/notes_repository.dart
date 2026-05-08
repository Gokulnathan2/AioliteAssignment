import 'dart:math';

import '../models/note.dart';
import '../models/queued_action.dart';
import '../storage/local_note_store.dart';
import '../sync/firebase_mock.dart';
import '../sync/idempotency.dart';
import '../sync/sync_logger.dart';
import '../sync/sync_queue.dart';

class NotesRepository {
  NotesRepository({
    required this.localStore,
    required this.queue,
    required this.firebase,
    required this.logger,
    this.userId = 'user_1',
  });   

  final LocalNoteStore localStore;
  final OfflineSyncQueue queue;
  final FirebaseMock firebase;
  final SyncLogger logger;
  final String userId;

  bool _refreshInFlight = false;

  String _newClientRequestId() {
    final rng = Random.secure();
    final value = List<int>.generate(16, (_) => rng.nextInt(256));
    return value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _newNoteId() {
    // Simple stable ID for demo purposes.
    return 'note_${_newClientRequestId()}';
  }

  Future<List<Note>> getNotes({Duration ttl = const Duration(seconds: 30)}) async {
    final cached = await localStore.getAllNotes();
    final updatedAtMillis = localStore.notesCacheUpdatedAtMillis;
    final nowMillis = DateTime.now().millisecondsSinceEpoch;

    final isStale = updatedAtMillis == null || (nowMillis - updatedAtMillis) > ttl.inMilliseconds;
    if (isStale && firebase.isOnline && !_refreshInFlight) {
      _refreshInFlight = true;
      logger.info('CACHE_STALE triggering background refresh (ttl=${ttl.inSeconds}s)');
      unawaited(_refreshFromServer().whenComplete(() => _refreshInFlight = false));
    }

    return cached;
  }

  Future<void> refreshFromServer() async {
    await _refreshFromServer();
  }

  Future<void> _refreshFromServer() async {
    final remoteNotes = firebase.fetchNotes();
    if (remoteNotes.isEmpty) {
      await localStore.clearAll();
      await localStore.setNotesCacheUpdatedAtNow();
      return;
    }

    for (final note in remoteNotes) {
      await localStore.upsertNote(note);
    }
    await localStore.setNotesCacheUpdatedAtNow();
  }

  Future<void> addNote(String text, {String? clientRequestId}) async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final noteId = _newNoteId();

    final note = Note(
      id: noteId,
      text: text,
      createdAtMillis: nowMillis,
      updatedAtMillis: nowMillis,
      likeCount: 0,
      likedByMe: false,
      savedByMe: false,
    );

    await localStore.upsertNote(note);
    logger.info('LOCAL_ADD noteId=$noteId');

    final requestId = clientRequestId ?? _newClientRequestId();
    final actionId = makeIdempotencyKey(
      actionType: queuedActionTypeToString(QueuedActionType.addNote),
      userId: userId,
      entityId: noteId,
      payload: <String, dynamic>{
        'noteId': noteId,
        'text': text,
        'createdAtMillis': nowMillis,
      },
      clientRequestId: requestId,
    );

    final action = QueuedAction(
      actionId: actionId,
      type: QueuedActionType.addNote,
      userId: userId,
      createdAtMillis: nowMillis,
      attempts: 0,
      nextAttemptAtMillis: nowMillis,
      payload: <String, dynamic>{
        'noteId': noteId,
        'text': text,
        'createdAtMillis': nowMillis,
      },
      permanentlyFailed: false,
    );

    await queue.enqueue(action);
    if (firebase.isOnline) {
      await queue.syncDueActions();
    }
  }

  Future<void> likeNote(
    String noteId, {
    required bool liked,
    String? clientRequestId,
  }) async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final existing = await localStore.getById(noteId);
    if (existing == null) {
      throw StateError('Missing local noteId=$noteId');
    }

    // Update local cache immediately (offline writes).
    //
    // Conflict strategy: last-write-wins.
    // Each queued action represents "set likedByMe=<liked>".
    // During sync, actions are processed in order; the last applied intent
    // wins, which matches how a boolean "liked" state is modeled.
    var nextLikeCount = existing.likeCount;
    if (!existing.likedByMe && liked) {
      nextLikeCount = existing.likeCount + 1;
    } else if (existing.likedByMe && !liked) {
      nextLikeCount = (existing.likeCount - 1).clamp(0, 1 << 60);
    }

    final updated = existing.copyWith(
      likedByMe: liked,
      likeCount: nextLikeCount,
      updatedAtMillis: nowMillis,
    );
    await localStore.upsertNote(updated);
    logger.info('LOCAL_LIKE noteId=$noteId liked=$liked');

    final requestId = clientRequestId ?? _newClientRequestId();
    final actionId = makeIdempotencyKey(
      actionType: queuedActionTypeToString(QueuedActionType.likeNote),
      userId: userId,
      entityId: noteId,
      payload: <String, dynamic>{
        'noteId': noteId,
        'liked': liked,
      },
      clientRequestId: requestId,
    );

    final action = QueuedAction(
      actionId: actionId,
      type: QueuedActionType.likeNote,
      userId: userId,
      createdAtMillis: nowMillis,
      attempts: 0,
      nextAttemptAtMillis: nowMillis,
      payload: <String, dynamic>{
        'noteId': noteId,
        'liked': liked,
      },
      permanentlyFailed: false,
    );

    await queue.enqueue(action);
    if (firebase.isOnline) {
      await queue.syncDueActions();
    }
  }

  Future<void> saveNote(
    String noteId, {
    required bool saved,
    String? clientRequestId,
  }) async { 
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final existing = await localStore.getById(noteId);
    if (existing == null) {
      throw StateError
    ('Missing local noteId=$noteId');
    }

    // Conflict strategy: last-write-wins.
    // Each queued action represents "set savedByMe=<saved>".
    final updated = existing.copyWith(
      savedByMe: saved,
      updatedAtMillis: nowMillis,
    );
    await localStore.upsertNote(updated);
    logger.info('LOCAL_SAVE noteId=$noteId saved=$saved');

    final requestId = clientRequestId ?? _newClientRequestId();
    final actionId = makeIdempotencyKey(
      actionType: queuedActionTypeToString(QueuedActionType.saveNote),
      userId: userId,
      entityId: noteId,
      payload: <String, dynamic>{
        'noteId': noteId,
        'saved': saved,
      },
      clientRequestId: requestId,
    );

    final action = QueuedAction(
      actionId: actionId,
      type: QueuedActionType.saveNote,
      userId: userId,
      createdAtMillis: nowMillis,
      attempts: 0,
      nextAttemptAtMillis: nowMillis,
      payload: <String, dynamic>{
        'noteId': noteId,
        'saved': saved,
      },
      permanentlyFailed: false,
    );

    await queue.enqueue(action);
    if (firebase.isOnline) {
      await queue.syncDueActions();
    }
  }

  Future<int> pendingQueueSize() => queue.pendingQueueSize();
}

/// Allows calling an async function without awaiting it.
void unawaited(Future<void> future) {}

