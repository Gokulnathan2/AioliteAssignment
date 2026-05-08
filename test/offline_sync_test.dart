import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:offline_app/offline/models/note.dart';
import 'package:offline_app/offline/repository/notes_repository.dart';
import 'package:offline_app/offline/storage/local_note_store.dart';
import 'package:offline_app/offline/sync/firebase_mock.dart';
import 'package:offline_app/offline/sync/sync_logger.dart';
import 'package:offline_app/offline/sync/sync_queue.dart';

class _Harness {
  _Harness({
    required this.repo,
    required this.firebase,
    required this.logger,
    required this.queue,
    required this.dirPath,
  });

  final NotesRepository repo;
  final FirebaseMock firebase;
  final SyncLogger logger;
  final OfflineSyncQueue queue;
  final String dirPath;
}

Future<_Harness> _buildTestHarness() async {
  final dir = await Directory.systemTemp.createTemp('offline_app_hive_');
  Hive.init(dir.path);

  final notesBox = await Hive.openBox<String>('notesBox');
  final queueBox = await Hive.openBox<String>('queueBox');
  final metaBox = await Hive.openBox<String>('metaBox');

  final logger = SyncLogger();
  final firebase = FirebaseMock(userId: 'user_1')..setOnline(false);

  final queue = OfflineSyncQueue(
    queueBox: queueBox,
    metaBox: metaBox,
    logger: logger,
    applier: firebase,
    backoffMillis: 10,
    maxRetries: 1,
  );

  final localStore = LocalNoteStore(notesBox: notesBox, metaBox: metaBox);
  final repo = NotesRepository(
    localStore: localStore,
    queue: queue,
    firebase: firebase,
    logger: logger,
    userId: 'user_1',
  );

  return _Harness(
    repo: repo,
    firebase: firebase,
    logger: logger,
    queue: queue,
    dirPath: dir.path,
  );
}

Future<void> _cleanupHarness() async {
  // Hive boxes are created per test; leave process cleanup to test end.
  await Hive.close();
}

void _assertContains(String full, Iterable<String> substrings) {
  for (final s in substrings) {
    expect(full.contains(s), true, reason: 'Missing substring: $s');
  }
}

void main() {
  test('Offline add note queues action and syncs later', () async {
    final harness = await _buildTestHarness();
    addTearDown(_cleanupHarness);

    final repo = harness.repo;
    final firebase = harness.firebase;
    final queue = harness.queue;
    final logger = harness.logger;

    await repo.addNote('hello offline');

    final localNotes = await repo.getNotes(ttl: const Duration(seconds: 1));
    expect(localNotes.length, 1);
    expect(await queue.pendingQueueSize(), 1);

    final noteId = localNotes.first.id;
    expect(firebase.getNote(noteId), isNull);

    firebase.setOnline(true);
    await queue.syncDueActions();

    expect(await queue.pendingQueueSize(), 0);
    expect(firebase.getNote(noteId), isNotNull);
    expect(firebase.appliedActionIds.length, 1);

    final logDump = logger.dump();
    _assertContains(logDump, <String>[
      'QUEUE_ENQUEUE',
      'pendingQueueSize=1',
      'SYNC_SUCCESS',
      'pendingQueueSize=0',
    ]);
  });

  test('Queue persists across restart and syncs later', () async {
    final harness = await _buildTestHarness();
    addTearDown(_cleanupHarness);

    final dirPath = harness.dirPath;
    final repo = harness.repo;
    final firebase = harness.firebase;
    final queue = harness.queue;
    final logger1 = harness.logger;

    firebase.setOnline(false);
    await repo.addNote('persist note');

    final localNotes = await repo.getNotes(ttl: const Duration(seconds: 60));
    expect(localNotes.length, 1);
    final noteId = localNotes.single.id;
    expect(await queue.pendingQueueSize(), 1);
    expect(firebase.appliedActionIds, isEmpty);

    // Simulate app restart: close Hive boxes, reopen from same directory.
    await Hive.close();
    Hive.init(dirPath);

    final notesBox2 = await Hive.openBox<String>('notesBox');
    final queueBox2 = await Hive.openBox<String>('queueBox');
    final metaBox2 = await Hive.openBox<String>('metaBox');

    final logger2 = SyncLogger();
    final queue2 = OfflineSyncQueue(
      queueBox: queueBox2,
      metaBox: metaBox2,
      logger: logger2,
      applier: firebase,
      backoffMillis: 10,
      maxRetries: 1,
    );
    final localStore2 = LocalNoteStore(notesBox: notesBox2, metaBox: metaBox2);
    final repo2 = NotesRepository(
      localStore: localStore2,
      queue: queue2,
      firebase: firebase,
      logger: logger2,
      userId: 'user_1',
    );

    // Pending queue survives restart.
    expect(await queue2.pendingQueueSize(), 1);
    expect(await repo2.getNotes(ttl: const Duration(seconds: 60)), isNotEmpty);

    firebase.setOnline(true);
    await queue2.syncDueActions();

    expect(await queue2.pendingQueueSize(), 0);
    expect(firebase.getNote(noteId), isNotNull);
    expect(firebase.appliedActionIds.length, 1);

    final logDump2 = logger2.dump();
    _assertContains(logDump2, <String>[
      'SYNC_ATTEMPT',
      'SYNC_SUCCESS',
      'pendingQueueSize=0',
    ]);

    // Keep log1 around so queue size changes are observable in this run.
    final logDump1 = logger1.dump();
    _assertContains(logDump1, <String>[
      'QUEUE_ENQUEUE',
      'pendingQueueSize=1',
    ]);
  });

  test('Offline like + save updates cache immediately and syncs', () async {
    final harness = await _buildTestHarness();
    addTearDown(_cleanupHarness);

    final repo = harness.repo;
    final firebase = harness.firebase;
    final queue = harness.queue;
    final logger = harness.logger;

    // Seed server note, refresh to populate local cache.
    const noteId = 'server_note_1';
    firebase.seedNote(
      Note(
        id: noteId,
        text: 'seeded',
        createdAtMillis: 1,
        updatedAtMillis: 1,
        likeCount: 0,
        likedByMe: false,
        savedByMe: false,
      ),
    );
    firebase.setOnline(true);
    await repo.refreshFromServer();

    final localBefore = await repo.getNotes(ttl: const Duration(seconds: 60));
    expect(localBefore.length, 1);

    // Go offline and perform offline writes.
    firebase.setOnline(false);
    await repo.likeNote(noteId, liked: true, clientRequestId: 'like_req_1');
    await repo.saveNote(noteId, saved: true, clientRequestId: 'save_req_1');

    final localAfter = await repo.getNotes(ttl: const Duration(seconds: 60));
    expect(localAfter.single.likedByMe, true);
    expect(localAfter.single.likeCount, 1);
    expect(localAfter.single.savedByMe, true);

    expect(await queue.pendingQueueSize(), 2);

    // Sync back online.
    firebase.setOnline(true);
    await queue.syncDueActions();

    final remote = firebase.getNote(noteId)!;
    expect(remote.likedByMe, true);
    expect(remote.likeCount, 1);
    expect(remote.savedByMe, true);
    expect(await queue.pendingQueueSize(), 0);
    expect(firebase.appliedActionIds.length, 2);

    final logDump = logger.dump();
    _assertContains(logDump, <String>[
      'QUEUE_ENQUEUE',
      'pendingQueueSize=2',
      'SYNC_SUCCESS',
    ]);
  });

  test('Retry once on transient failure preserves exactly-once', () async {
    final harness = await _buildTestHarness();
    addTearDown(_cleanupHarness);

    final repo = harness.repo;
    final firebase = harness.firebase;
    final queue = harness.queue;
    final logger = harness.logger;

    // Online, but make the backend fail once.
    firebase.setOnline(true);
    firebase.setTransientFailure(1, applyThenThrow: true);

    await repo.addNote('retry note');

    // The first sync attempt should have failed and scheduled a retry.
    expect(await queue.pendingQueueSize(), 1);
    expect(firebase.appliedActionIds.length, 1); // action applied once, then threw.

    // Wait for backoff to elapse.
    await Future.delayed(const Duration(milliseconds: 30));
    await queue.syncDueActions();

    expect(await queue.pendingQueueSize(), 0);
    expect(firebase.appliedActionIds.length, 1); // no duplicates on retry.

    final logDump = logger.dump();
    _assertContains(logDump, <String>[
      'SYNC_ATTEMPT',
      'SYNC_FAIL_RETRY_SCHEDULE',
      'SYNC_SUCCESS',
    ]);
  });

  test('Queue dedups by idempotency key (same request id)', () async {
    final harness = await _buildTestHarness();
    addTearDown(_cleanupHarness);

    final repo = harness.repo;
    final firebase = harness.firebase;
    final queue = harness.queue;
    final logger = harness.logger;

    // Add a note locally without syncing.
    firebase.setOnline(false);
    await repo.addNote('dedup note');
    final localNotes = await repo.getNotes(ttl: const Duration(seconds: 60));
    final noteId = localNotes.single.id;
    expect(await queue.pendingQueueSize(), 1);

    // Apply the same like intent twice offline with same clientRequestId => same actionId.
    await repo.likeNote(noteId, liked: true, clientRequestId: 'dup_like_req');
    await repo.likeNote(noteId, liked: true, clientRequestId: 'dup_like_req');

    // There should be only one like action queued (plus the add note action).
    final pending = await queue.pendingQueueSize();
    expect(pending, 2);

    final logDump = logger.dump();
    _assertContains(logDump, <String>[
      'QUEUE_ENQUEUE_DEDUP',
    ]);
  });
}

