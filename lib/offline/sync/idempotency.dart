import 'dart:convert';

import 'package:crypto/crypto.dart';

String sha256Hex(String input) {
  final bytes = utf8.encode(input);
  final digest = sha256.convert(bytes);
  return digest.toString();
}

/// Generates a stable idempotency key for a given offline intent.
///
/// Note: we include an explicit `clientRequestId` so the key can be
/// reproduced deterministically if the same intent is re-created.
String makeIdempotencyKey({
  required String actionType,
  required String userId,
  required String entityId,
  required Map<String, dynamic> payload,
  required String clientRequestId,
}) {
  final normalizedPayload = jsonEncode(payload);
  return sha256Hex(
    [
      'actionType=$actionType',
      'userId=$userId',
      'entityId=$entityId',
      'payload=$normalizedPayload',
      'clientRequestId=$clientRequestId',
    ].join('|'),
  );
}

