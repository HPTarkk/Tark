import 'dart:async';
import 'dart:convert';

import 'package:dartz/dartz.dart';
import 'package:http/http.dart' as http;

import '../utils/logger.dart';
import 'api_client.dart';
import 'api_failure.dart';

/// [ApiClient] over `package:http`.
///
/// The whole class is the boundary between "something went wrong on a
/// network" and the closed [ApiFailure] set the rest of the app reasons
/// about. Nothing below this line throws.
/// Registered by `NetworkModule` rather than annotated: the optional
/// constructor argument is a test seam, and injectable would try to
/// resolve an `http.Client` for it.
class HttpApiClient implements ApiClient {
  HttpApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<Either<ApiFailure, Map<String, dynamic>>> getJson(
    Uri url, {
    Duration timeout = ApiLimits.timeout,
    int maxBytes = ApiLimits.maxBytes,
  }) async {
    // Refuse anything that is not HTTPS before a packet moves. The app only
    // ever fetches its own published documents, so there is no legitimate
    // plaintext case, and a URL that arrived from a config or a build flag
    // should not be able to downgrade the transport silently.
    if (url.scheme != 'https') {
      return Left(MalformedResponse('refusing non-https URL: ${url.scheme}'));
    }

    try {
      // send() rather than get(): a streamed response is what makes the byte
      // ceiling meaningful. http.get() reads the whole body first, so a
      // limit checked afterwards has already cost the download.
      final request = http.Request('GET', url)
        ..headers['Accept'] = 'application/json';

      final response = await _client.send(request).timeout(timeout);

      if (response.statusCode != 200) {
        return Left(
          BadStatus(response.statusCode, 'GET $url → ${response.statusCode}'),
        );
      }

      // A server that declares an oversized body is refused before reading
      // it; one that declares nothing is cut off mid-stream below.
      final declared = response.contentLength;
      if (declared != null && declared > maxBytes) {
        return Left(
          ResponseTooLarge('$url declared $declared bytes, ceiling $maxBytes'),
        );
      }

      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) {
          return Left(
            ResponseTooLarge('$url exceeded $maxBytes bytes mid-stream'),
          );
        }
      }

      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        return Left(
          MalformedResponse('$url returned ${decoded.runtimeType}, want an object'),
        );
      }
      return Right(decoded);
    } on TimeoutException catch (e) {
      return Left(RequestTimedOut('GET $url timed out: $e'));
    } on FormatException catch (e) {
      // Both malformed UTF-8 and malformed JSON land here, and neither gets
      // better by asking again.
      return Left(MalformedResponse('GET $url returned undecodable body: $e'));
    } catch (e) {
      // Everything left is the network refusing to cooperate: SocketException
      // and HandshakeException on mobile, ClientException on web, plus
      // whatever a platform invents. Caught broadly on purpose — an
      // uncatalogued transport error must not escape a background refresh as
      // an unhandled async error.
      Logger.log('ApiClient: GET $url failed — $e');
      return Left(NetworkUnreachable('GET $url failed: $e'));
    }
  }

  @override
  void close() => _client.close();
}
