import 'package:dartz/dartz.dart';

import 'api_failure.dart';

/// The app's one way of talking to something over HTTP.
///
/// ## Why this exists at all, in an app that is proud of having no backend
///
/// Tark's whole promise is that a conversation never leaves the local link,
/// and that is still true: nothing here carries voice, presence, peers or
/// anything a user said. This client fetches **published documents** — the
/// privacy policy and the terms, from the same static files the website
/// renders — so the app can notice that a newer version exists.
///
/// It is written as an interface rather than a `http.get` at the call site
/// for the reasons that always apply, plus one that is specific here:
///
/// * **Tests must not touch the network.** Every consumer takes this type,
///   so a test hands it a fake and the suite stays offline and instant.
/// * **The guest web build shares `core/`.** `dart:io` does not compile for
///   web, so the transport choice has to live behind something.
/// * **The failure vocabulary is the point.** Callers here do not want an
///   exception; they want to know whether to keep what they already had. See
///   [ApiFailure.isRetryable].
///
/// ## The rules this client keeps, so no call site has to
///
/// * **Never throws.** Every outcome is an [Either]. A background refresh
///   that throws on a phone with no signal is a crash report, not a feature.
/// * **Always bounded.** Every request has a timeout and a byte ceiling.
/// * **Only GET, only JSON.** There is nothing to POST — the app has no
///   account and no server of its own — and adding a verb it does not need
///   would be inviting a use this design has not thought about.
abstract interface class ApiClient {
  /// Fetches [url] and decodes it as a JSON object.
  ///
  /// [maxBytes] rejects a body larger than the caller expects; [timeout]
  /// bounds the whole exchange, connection included. Both have defaults
  /// suited to fetching a small published document over a bad connection.
  ///
  /// Returns [MalformedResponse] when the body is not JSON, or is JSON that
  /// is not an object — a caller asking for a document should not have to
  /// handle being handed a bare list or a number.
  Future<Either<ApiFailure, Map<String, dynamic>>> getJson(
    Uri url, {
    Duration timeout,
    int maxBytes,
  });

  /// Releases any underlying connection pool.
  ///
  /// Held open across the process by design — the DI graph owns one instance
  /// — so in practice only tests call this.
  void close();
}

/// Ceilings shared by the interface's defaults and its implementation, so a
/// fake in a test is bounded the same way the real client is.
abstract final class ApiLimits {
  /// Long enough to survive a slow handshake on a weak connection, short
  /// enough that a background check never sits on a socket for a minute.
  static const timeout = Duration(seconds: 15);

  /// The largest document this app ever asks for is the privacy policy, at
  /// roughly 50 KB. A quarter of a megabyte is generous headroom and still
  /// small enough that a wrong URL cannot cost anybody real data.
  static const maxBytes = 256 * 1024;
}
