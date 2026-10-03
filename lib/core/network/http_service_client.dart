import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/logger.dart';
import 'api_failure.dart';
import 'service_api.dart';

/// [TarkServiceClient] over `package:http`, with the same rules as
/// [HttpApiClient]: HTTPS only (except a backend on this machine or the
/// local network, see [allowsPlainHttp]), every exchange bounded in time and
/// bytes, and nothing below this line throws.
///
/// Logs method, path and status only. Bodies carry passwords, codes and
/// tokens, and none of that belongs in a diagnostic log.
class HttpTarkServiceClient implements TarkServiceClient {
  HttpTarkServiceClient({
    Uri? baseUrl,
    http.Client? client,
    Future<Map<String, String>> Function()? commonHeaders,
    Duration timeout = TarkApiConfig.timeout,
    int maxBytes = TarkApiConfig.maxBytes,
  }) : _base = baseUrl ?? Uri.parse(TarkApiConfig.baseUrl),
       _client = client ?? http.Client(),
       _commonHeaders = commonHeaders,
       _timeout = timeout,
       _maxBytes = maxBytes;

  final Uri _base;
  final http.Client _client;
  final Future<Map<String, String>> Function()? _commonHeaders;
  final Duration _timeout;
  final int _maxBytes;

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    final method = request.method.name.toUpperCase();
    final label = '$method ${request.path}';
    if (_base.scheme != 'https' && !allowsPlainHttp(_base)) {
      return ApiTransportFailure(
        MalformedResponse('refusing non-https API base: ${_base.scheme}'),
      );
    }
    final basePath = _base.path.endsWith('/')
        ? _base.path.substring(0, _base.path.length - 1)
        : _base.path;
    final url = _base.replace(path: '$basePath${request.path}');

    try {
      final outgoing = http.Request(method, url)
        ..headers['Accept'] = 'application/json';
      final common = _commonHeaders;
      if (common != null) {
        try {
          outgoing.headers.addAll(await common());
        } catch (error) {
          // A header we could not compute (the install key, say) is left
          // off: every such header is optional for the calls that allow it.
          Logger.log('API: common headers unavailable ($error)');
        }
      }
      outgoing.headers.addAll(request.headers);
      final key = request.idempotencyKey;
      if (key != null) outgoing.headers['Idempotency-Key'] = key;
      final body = request.body;
      if (body != null) {
        outgoing.headers['Content-Type'] = 'application/json';
        outgoing.body = jsonEncode(body);
      }

      final response = await _client.send(outgoing).timeout(_timeout);
      final declared = response.contentLength;
      if (declared != null && declared > _maxBytes) {
        return ApiTransportFailure(
          ResponseTooLarge('$label declared $declared bytes'),
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBytes) {
          return ApiTransportFailure(
            ResponseTooLarge('$label exceeded $_maxBytes bytes'),
          );
        }
      }

      final status = response.statusCode;
      Logger.log('API: $label → $status');
      final decoded = bytes.isEmpty ? null : _tryDecode(bytes);

      if (status >= 200 && status < 300) {
        if (bytes.isEmpty) {
          return ApiOk(status, const {}, headers: response.headers);
        }
        if (decoded is! Map<String, dynamic>) {
          return ApiTransportFailure(
            MalformedResponse('$label returned a non-object body'),
          );
        }
        return ApiOk(status, decoded, headers: response.headers);
      }

      // A failure. The Problem shape when the server wrote one; a proxy or
      // gateway page otherwise, which gets a synthetic code so callers still
      // branch on status alone.
      final problem = decoded is Map<String, dynamic> ? decoded : null;
      final code = problem?['code'];
      final fields = <String, dynamic>{...?problem}
        ..remove('code')
        ..remove('detail');
      return ApiProblem(
        status,
        code is String && code.isNotEmpty ? code : 'http_$status',
        fields: fields,
        retryAfter: _retryAfter(problem, response.headers),
      );
    } on TimeoutException catch (e) {
      Logger.log('API: $label timed out');
      return ApiTransportFailure(RequestTimedOut('$label timed out: $e'));
    } catch (e) {
      // SocketException, HandshakeException, ClientException and whatever a
      // platform invents: the network refused to cooperate.
      Logger.log('API: $label failed (${e.runtimeType})');
      return ApiTransportFailure(NetworkUnreachable('$label failed: $e'));
    }
  }

  static Object? _tryDecode(List<int> bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
  }

  static Duration? _retryAfter(
    Map<String, dynamic>? problem,
    Map<String, String> headers,
  ) {
    final ms = problem?['retryAfterMs'];
    if (ms is num && ms >= 0) return Duration(milliseconds: ms.toInt());
    final seconds = int.tryParse(headers['retry-after'] ?? '');
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    return null;
  }

  @override
  void close() => _client.close();
}
