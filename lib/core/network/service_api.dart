import 'dart:math';

import 'api_failure.dart';

/// The Tark backend's own API (backend/api/openapi.yaml), as opposed to the
/// static published documents [ApiClient] fetches.
///
/// Where the backend lives. Overridable per build so a staging server can be
/// used without touching code:
///
///   flutter run --dart-define=TARK_API_BASE=https://staging.example/v1
///
/// A backend on the local network may use plain http (see
/// [allowsPlainHttp]); Android then also needs cleartext allowed for that
/// build (`android:usesCleartextTraffic="true"`).
abstract final class TarkApiConfig {
  static const baseUrl = String.fromEnvironment(
    'TARK_API_BASE',
    defaultValue: 'https://api.tarkk.ir/v1',
  );

  /// Every answer from the backend is a small JSON document: a profile, a
  /// token pair, a signed entitlement. 64 KB is far above any of them.
  static const maxBytes = 64 * 1024;

  /// Long enough for a slow mobile handshake, short enough that a sign-in
  /// button never spins for a minute.
  static const timeout = Duration(seconds: 20);
}

/// Whether [base] may be reached over plain `http`: only a backend on this
/// machine or on a private network (`localhost`, 127/8, 10/8, 172.16/12,
/// 192.168/16, which covers the emulator's 10.0.2.2), so a developer can
/// sign in against a backend on their laptop. Anything reachable from the
/// internet stays HTTPS only.
bool allowsPlainHttp(Uri base) {
  if (base.scheme != 'http') return false;
  final host = base.host.toLowerCase();
  if (host == 'localhost') return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList();
  if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
  final a = octets[0]!, b = octets[1]!;
  return a == 127 ||
      a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}

enum ApiMethod { get, post, put }

/// One call to the backend, relative to [TarkApiConfig.baseUrl].
class ApiRequest {
  const ApiRequest(
    this.method,
    this.path, {
    this.body,
    this.headers = const {},
    this.idempotencyKey,
  });

  const ApiRequest.get(String path, {Map<String, String> headers = const {}})
    : this(ApiMethod.get, path, headers: headers);

  const ApiRequest.post(
    String path, {
    Map<String, Object?>? body,
    Map<String, String> headers = const {},
    String? idempotencyKey,
  }) : this(
         ApiMethod.post,
         path,
         body: body,
         headers: headers,
         idempotencyKey: idempotencyKey,
       );

  final ApiMethod method;

  /// Starts with `/`, e.g. `/auth/login`.
  final String path;
  final Map<String, Object?>? body;
  final Map<String, String> headers;

  /// Sent as `Idempotency-Key`. A retry of the same write must reuse it, so
  /// the server replays its first answer instead of acting twice.
  final String? idempotencyKey;
}

/// How a call to the backend ended. A closed set, and no call throws:
/// every screen needs to tell "the server said no" from "we never reached
/// it", and an exception cannot carry that without a catch at every site.
sealed class ApiResponse {
  const ApiResponse();
}

/// A 2xx answer. [body] is empty for 204.
final class ApiOk extends ApiResponse {
  const ApiOk(this.statusCode, this.body, {this.headers = const {}});

  final int statusCode;
  final Map<String, dynamic> body;

  /// Lower-case names.
  final Map<String, String> headers;
}

/// The server answered with a failure, in the one Problem shape. [code] is
/// the stable machine-readable part; `detail` is deliberately not kept here
/// at all, so nothing can show it to people.
final class ApiProblem extends ApiResponse {
  const ApiProblem(
    this.statusCode,
    this.code, {
    this.fields = const {},
    this.retryAfter,
  });

  final int statusCode;
  final String code;

  /// The Problem's extra members (`attemptsLeft`, `ticket`, `email`, ...),
  /// without `detail`.
  final Map<String, dynamic> fields;

  /// From `retryAfterMs` or the Retry-After header, when the server gave one.
  final Duration? retryAfter;

  int? intField(String name) {
    final value = fields[name];
    return value is int ? value : (value is num ? value.toInt() : null);
  }

  String? stringField(String name) {
    final value = fields[name];
    return value is String ? value : null;
  }

  bool? boolField(String name) {
    final value = fields[name];
    return value is bool ? value : null;
  }

  @override
  String toString() => 'ApiProblem($statusCode, $code)';
}

/// The call never produced a usable answer: no connection, a timeout, or a
/// reply that was not JSON or was too large.
final class ApiTransportFailure extends ApiResponse {
  const ApiTransportFailure(this.failure);

  final ApiFailure failure;

  /// True when the phone could not reach the server at all (or it did not
  /// answer in time) — the "check your connection" case. False when a reply
  /// arrived but was broken, which is our side's trouble, not theirs.
  bool get unreachable =>
      failure is NetworkUnreachable || failure is RequestTimedOut;

  @override
  String toString() => 'ApiTransportFailure($failure)';
}

/// The call needs a signed-in account and this phone has none, or its
/// session ended (refresh refused). Never sent to the network.
final class ApiSignedOut extends ApiResponse {
  const ApiSignedOut();
}

/// Sends [ApiRequest]s to the backend. Adds the headers every call carries
/// (platform, install key, JSON) and nothing else: bearer tokens and refresh
/// are [AuthenticatedApiClient]'s job, one layer up.
abstract interface class TarkServiceClient {
  Future<ApiResponse> send(ApiRequest request);

  void close();
}

/// A fresh random (version 4) UUID for an `Idempotency-Key`.
String newIdempotencyKey([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int from, int to) => bytes
      .sublist(from, to)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
