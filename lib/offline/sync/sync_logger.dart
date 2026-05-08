import 'package:flutter/foundation.dart';

class SyncLogEntry {
  SyncLogEntry(this.message, this.timestampMillis);

  final String message;
  final int timestampMillis;
}

class SyncLogger {
  final List<SyncLogEntry> entries = <SyncLogEntry>[];

  void info(String message) {
    final now = DateTime.now().millisecondsSinceEpoch;
    entries.add(SyncLogEntry(message, now));
    debugPrint('[offline-sync] $message');
  }

  String dump() => entries.map((e) => e.message).join('\n');
}

