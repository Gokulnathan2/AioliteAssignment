import 'dart:convert';

enum QueuedActionType {
  addNote,
  likeNote,
  saveNote,
}

QueuedActionType queuedActionTypeFromString(String value) {
  switch (value) {
    case 'addNote':
      return QueuedActionType.addNote;
    case 'likeNote':
      return QueuedActionType.likeNote;
    case 'saveNote':
      return QueuedActionType.saveNote;
    default:
      throw ArgumentError('Unknown queued action type: $value');
  }
}

String queuedActionTypeToString(QueuedActionType type) {
  switch (type) {
    case QueuedActionType.addNote:
      return 'addNote';
    case QueuedActionType.likeNote:
      return 'likeNote';
    case QueuedActionType.saveNote:
      return 'saveNote';
  }
}

/// Represents an offline intent that must be applied exactly-once remotely.
///
/// Idempotency is handled by storing an `actionId` (client-generated stable
/// idempotency key). The backend mock treats the same `actionId` as applied
/// and won't re-apply it on retries.
class QueuedAction {
  QueuedAction({
    required this.actionId,
    required this.type,
    required this.userId,
    required this.createdAtMillis,
    required this.attempts,
    required this.nextAttemptAtMillis,
    required this.payload,
    required this.permanentlyFailed,
    this.lastError,
  });

  final String actionId;
  final QueuedActionType type;
  final String userId;
  final int createdAtMillis;

  /// Number of attempts already performed (0 = first attempt not yet made).
  final int attempts;

  /// Milliseconds since epoch when this action is eligible to retry.
  final int nextAttemptAtMillis;

  final Map<String, dynamic> payload;

  final bool permanentlyFailed;
  final String? lastError;

  QueuedAction copyWith({
    String? actionId,
    QueuedActionType? type,
    String? userId,
    int? createdAtMillis,
    int? attempts,
    int? nextAttemptAtMillis,
    Map<String, dynamic>? payload,
    bool? permanentlyFailed,
    String? lastError,
  }) {
    return QueuedAction(
      actionId: actionId ?? this.actionId,
      type: type ?? this.type,
      userId: userId ?? this.userId,
      createdAtMillis: createdAtMillis ?? this.createdAtMillis,
      attempts: attempts ?? this.attempts,
      nextAttemptAtMillis: nextAttemptAtMillis ?? this.nextAttemptAtMillis,
      payload: payload ?? this.payload,
      permanentlyFailed: permanentlyFailed ?? this.permanentlyFailed,
      lastError: lastError ?? this.lastError,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'actionId': actionId,
        'type': queuedActionTypeToString(type),
        'userId': userId,
        'createdAtMillis': createdAtMillis,
        'attempts': attempts,
        'nextAttemptAtMillis': nextAttemptAtMillis,
        'payload': payload,
        'permanentlyFailed': permanentlyFailed,
        'lastError': lastError,
      };

  static QueuedAction fromJson(Map<String, dynamic> json) => QueuedAction(
        actionId: json['actionId'] as String,
        type: queuedActionTypeFromString(json['type'] as String),
        userId: json['userId'] as String,
        createdAtMillis: json['createdAtMillis'] as int,
        attempts: json['attempts'] as int,
        nextAttemptAtMillis: json['nextAttemptAtMillis'] as int,
        payload: (json['payload'] as Map).cast<String, dynamic>(),
        permanentlyFailed: json['permanentlyFailed'] as bool,
        lastError: json['lastError'] as String?,
      );

  String toJsonString() => jsonEncode(toJson());

  static QueuedAction fromJsonString(String jsonString) =>
      fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
}

