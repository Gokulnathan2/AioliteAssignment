import 'package:hive/hive.dart';

import '../models/note.dart';

/// Hive-backed local cache for notes.
///
/// - Notes are stored by `note.id` as `String -> String(json)`.
/// - Read is local-first; sync queue is responsible for remote propagation.
class LocalNoteStore {
  LocalNoteStore({
    required this.notesBox,
    required this.metaBox,
  });

  final Box<String> notesBox;
  final Box<String> metaBox;

  static const String metaNotesCacheUpdatedAtMillisKey =
      'notesCacheUpdatedAtMillis';

  int? get notesCacheUpdatedAtMillis {
    final value = metaBox.get(metaNotesCacheUpdatedAtMillisKey);
    if (value == null) return null;
    return int.tryParse(value);
  }

  Future<List<Note>> getAllNotes() async {
    final notes = <Note>[];
    for (final key in notesBox.keys) {
      final json = notesBox.get(key);
      if (json == null) continue;
      final note = Note.fromJsonString(json);
      notes.add(note);
    }
    // Stable ordering for tests/UI
    notes.sort((a, b) => b.updatedAtMillis.compareTo(a.updatedAtMillis));
    return notes;
  }

  Future<Note?> getById(String noteId) async {
    final json = notesBox.get(noteId);
    if (json == null) return null;
    return Note.fromJsonString(json);
  }

  Future<void> upsertNote(Note note) async {
    await notesBox.put(note.id, note.toJsonString());
  }

  Future<void> clearAll() async {
    await notesBox.clear();
    await metaBox.delete(metaNotesCacheUpdatedAtMillisKey);
  }

  Future<void> setNotesCacheUpdatedAtNow() async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch.toString();
    await metaBox.put(metaNotesCacheUpdatedAtMillisKey, nowMillis);
  }
}

