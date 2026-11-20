import 'dart:async';

import 'package:http/http.dart' as http;

/// Bounds the whole exchange, including the body, and releases the connection
/// when it times out or the caller stops reading early.
Future<T> withHttpDeadline<T>(
  Duration timeout,
  Future<T> Function(Completer<void> abort) exchange,
) async {
  final abort = Completer<void>();
  try {
    return await exchange(abort).timeout(timeout);
  } finally {
    abort.complete();
  }
}

/// Releases a streamed response whose status or headers already rule it out.
Future<void> discardHttpBody(http.StreamedResponse response) =>
    response.stream.listen(null, onError: (Object _) {}).cancel();
