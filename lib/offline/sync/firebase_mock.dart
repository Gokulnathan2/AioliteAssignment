import '../models/note.dart';
import '../models/queued_action.dart';
import 'sync_queue.dart';

/// Represents a connectivity problem for the backend.
class OfflineException implements Exception {
  OfflineException(this.message);
  final String message;

  @override
  String toString() => 'OfflineException: $message';
}

/// Represents a transient retryable failure.
class TransientNetworkException implements Exception {
  TransientNetworkException(this.message);
  final String message;

  @override
  String toString() => 'TransientNetworkException: $message';
}

/// In-memory mock of a Firebase-like backend with exactly-once semantics
/// based on `actionId`.
///
/// - If an `actionId` was already applied, subsequent calls are idempotent.
/// - If a transient failure is configured to happen "after applying", the
///   first attempt both applies the mutation and then throws, so that a
///   retry will hit the idempotency check and not create duplicates.
class FirebaseMock implements RemoteActionApplier {
  FirebaseMock({this.userId = 'user_1'});

  final String userId;

  bool _online = true;

  /// Number of upcoming failures to trigger.
  int _transientFailuresRemaining = 0;

  /// If true, we apply the action then throw on that attempt.
  bool _failAfterApplying = true;

  /// Exactly-once tracking on the backend.
  final Set<String> appliedActionIds = <String>{};

  /// Server-side note state keyed by noteId.
  final Map<String, Note> _notesById = <String, Note>{};

  void setOnline(bool online) {
    _online = online;
  }

  bool get isOnline => _online;

  /// Configure N transient failures to happen on the next N `applyAction`
  /// calls. If `applyThenThrow=true`, the mutation is applied before throwing.
  void setTransientFailure(int count, {bool applyThenThrow = true}) {
    _transientFailuresRemaining = count;
    _failAfterApplying = applyThenThrow;
  }

  List<Note> fetchNotes() {
    final notes = _notesById.values.toList();
    notes.sort((a, b) => b.updatedAtMillis.compareTo(a.updatedAtMillis));
    return notes;
  }

  void seedNote(Note note) {
    _notesById[note.id] = note;
  }

  Note? getNote(String noteId) => _notesById[noteId];

  @override
  Future<void> applyAction(QueuedAction action) async {
    if (!_online) {
      throw OfflineException('Backend is offline');
    }

    // Exactly-once guarantee by idempotency key.
    if (appliedActionIds.contains(action.actionId)) {
      return;
    }

    // Apply mutation.
    _applyMutation(action);
    appliedActionIds.add(action.actionId);

    // Optional transient failure injection after applying.
    if (_transientFailuresRemaining > 0) {
      _transientFailuresRemaining--;
      if (_failAfterApplying) {
        throw TransientNetworkException(
          'Injected transient failure after applying (for retry test)',
        );
      }
    }
  }

  void _applyMutation(QueuedAction action) {
    switch (action.type) {
      case QueuedActionType.addNote:
        final payload = action.payload;
        final noteId = payload['noteId'] as String;
        final text = payload['text'] as String;
        final createdAtMillis = payload['createdAtMillis'] as int;

        _notesById.putIfAbsent(
          noteId,
          () => Note(
            id: noteId,
            text: text,
            createdAtMillis: createdAtMillis,
            updatedAtMillis: createdAtMillis,
            likeCount: 0,
            likedByMe: false,
            savedByMe: false,
          ),
        );
        // If already existed (e.g., same noteId), keep server state; idempotency
        // is handled at actionId level.
        break;
      case QueuedActionType.likeNote:
        final payload = action.payload;
        final noteId = payload['noteId'] as String;
        final liked = payload['liked'] as bool;
        final nowMillis = DateTime.now().millisecondsSinceEpoch;

        final existing = _notesById[noteId];
        if (existing == null) {
          throw StateError('Cannot like missing noteId=$noteId');
        }

        final alreadyLiked = existing.likedByMe;
        var likeCount = existing.likeCount;
        if (!alreadyLiked && liked) {
          likeCount = likeCount + 1;
        } else if (alreadyLiked && !liked) {
          likeCount = (likeCount - 1).clamp(0, 1 << 60);
        }

        _notesById[noteId] = existing.copyWith(
          likedByMe: liked,
          likeCount: likeCount,
          updatedAtMillis: nowMillis,
        );
        break;
      case QueuedActionType.saveNote:
        final payload = action.payload;
        final noteId = payload['noteId'] as String;
        final saved = payload['saved'] as bool;
        final nowMillis = DateTime.now().millisecondsSinceEpoch;

        final existing = _notesById[noteId];
        if (existing == null) {
          throw StateError('Cannot save missing noteId=$noteId');
        }

        _notesById[noteId] = existing.copyWith(
          savedByMe: saved,
          updatedAtMillis: nowMillis,
        );
        break;
    }
  }
}

