import 'package:equatable/equatable.dart';

/// Why a request did not produce a usable body.
///
/// A closed set, and deliberately a small one. Every caller in this app has
/// the same decision to make — *can I act on this, or do I carry on with what
/// I already had?* — and a taxonomy finer than that would only invite call
/// sites to branch on distinctions they cannot actually do anything about.
///
/// The one distinction that does change behaviour is [isRetryable]: a
/// timeout on a train is worth trying again in ten minutes, a 404 is not.
sealed class ApiFailure extends Equatable {
  const ApiFailure(this.message);

  /// For the diagnostic log, never for a screen. Nothing here is phrased for
  /// a reader, and none of it is translated.
  final String message;

  /// Whether the same request, unchanged, could plausibly succeed later.
  ///
  /// The caller that matters here is the background policy check, which runs
  /// on whatever connection the phone happens to have. Treating "no route to
  /// host" as permanent would mean one flight-mode launch stops the app ever
  /// noticing a new privacy policy again.
  bool get isRetryable;

  @override
  List<Object?> get props => [runtimeType, message];

  @override
  String toString() => '$runtimeType($message)';
}

/// The request never reached a server: no connectivity, DNS, TLS, refused.
final class NetworkUnreachable extends ApiFailure {
  const NetworkUnreachable(super.message);

  @override
  bool get isRetryable => true;
}

/// A server answered, but not in time.
final class RequestTimedOut extends ApiFailure {
  const RequestTimedOut(super.message);

  @override
  bool get isRetryable => true;
}

/// A server answered with a status this client will not accept.
final class BadStatus extends ApiFailure {
  const BadStatus(this.statusCode, super.message);

  final int statusCode;

  /// 5xx and 429 are the server's problem and usually temporary; 4xx means
  /// this request is wrong and will stay wrong.
  @override
  bool get isRetryable => statusCode >= 500 || statusCode == 429;

  @override
  List<Object?> get props => [runtimeType, statusCode, message];
}

/// The body arrived but is not what the caller was promised — malformed
/// JSON, the wrong shape, a schema this build does not understand.
///
/// Not retryable: fetching the same broken document again produces the same
/// broken document. This is the failure that protects an app whose only
/// remote dependency is a static file somebody could publish a typo into.
final class MalformedResponse extends ApiFailure {
  const MalformedResponse(super.message);

  @override
  bool get isRetryable => false;
}

/// The response was larger than the caller said it would accept.
///
/// A ceiling exists because the client is pointed at a URL rather than at a
/// contract: a misconfigured host, a captive portal, or a redirect to
/// something enormous should cost this app a few kilobytes, not a phone's
/// data allowance.
final class ResponseTooLarge extends ApiFailure {
  const ResponseTooLarge(super.message);

  @override
  bool get isRetryable => false;
}
