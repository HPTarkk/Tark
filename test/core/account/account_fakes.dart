import 'package:tark/core/account/account_session.dart';
import 'package:tark/core/account/account_store.dart';
import 'package:tark/core/account/auth_repository.dart';
import 'package:tark/core/account/google_id_token_source.dart';
import 'package:tark/core/network/authenticated_api_client.dart';
import 'package:tark/core/network/service_api.dart';
import 'package:tark/core/security/app_secure_storage.dart';

/// A backend in a map: each request is answered by [handler], and every
/// request is recorded (with the headers it went out with) for assertions.
class FakeServiceClient implements TarkServiceClient {
  FakeServiceClient([this.handler]);

  Future<ApiResponse> Function(ApiRequest request)? handler;
  final requests = <ApiRequest>[];

  List<String> get paths => [for (final r in requests) r.path];

  Iterable<ApiRequest> to(String path) => requests.where((r) => r.path == path);

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    requests.add(request);
    final h = handler;
    if (h == null) return const ApiProblem(500, 'no_handler');
    return h(request);
  }

  @override
  void close() {}
}

class FakeGoogle implements GoogleIdTokenSource {
  FakeGoogle({this.available = true, this.result});

  @override
  bool available;
  GoogleTokenResult? result;
  final nonces = <String>[];

  @override
  Future<GoogleTokenResult> idToken({required String nonce}) async {
    nonces.add(nonce);
    return result ?? GoogleToken('google-id-token-for-$nonce');
  }
}

const farFuture = 4102444800000; // 2100-01-01

Map<String, Object?> tokensJson({
  String access = 'access-1',
  String refresh = 'refresh-1',
  int accessExp = farFuture,
}) => {
  'accessToken': access,
  'accessTokenExpiresAt': accessExp,
  'refreshToken': refresh,
  'refreshTokenExpiresAt': farFuture,
};

Map<String, Object?> profileJson({
  String name = 'Pedi',
  String email = 'pedi@example.com',
  String? avatarId = '3',
  List<String> methods = const ['password'],
}) => {
  'id': '8a3c1b2e-0000-4000-8000-000000000001',
  'name': name,
  'avatarId': avatarId,
  'email': email,
  'signInMethods': methods,
  'createdAt': 1,
  'updatedAt': 2,
};

Map<String, dynamic> sessionJson({
  String access = 'access-1',
  String refresh = 'refresh-1',
  Map<String, Object?>? profile,
}) => {
  ...tokensJson(access: access, refresh: refresh),
  'newAccount': false,
  'profile': profile ?? profileJson(),
};

Map<String, dynamic> flowJson({
  String flowId = 'flow-1',
  int resendAt = 0,
  int expiresAt = farFuture,
}) => {
  'flowId': flowId,
  'expiresAt': expiresAt,
  'resendAvailableAt': resendAt,
  'code': {'length': 6, 'alphabet': 'digits'},
};

/// The whole account stack over [client], in memory.
class AccountHarness {
  AccountHarness({
    FakeServiceClient? client,
    FakeGoogle? google,
    DateTime Function()? clock,
    this.localName = 'Pedi',
  }) : client = client ?? FakeServiceClient(),
       google = google ?? FakeGoogle(),
       storage = MemoryAppSecureStorage() {
    store = AccountStore(storage);
    api = AuthenticatedApiClient(this.client, store, clock: clock);
    session = AccountSession(api: api, store: store, available: true);
    repository = AuthRepository(
      session: session,
      store: store,
      google: this.google,
      localeCode: () async => 'fa',
      localName: () async => localName,
    );
  }

  final FakeServiceClient client;
  final FakeGoogle google;
  final MemoryAppSecureStorage storage;
  String localName;
  late final AccountStore store;
  late final AuthenticatedApiClient api;
  late final AccountSession session;
  late final AuthRepository repository;

  /// Signs in as if a sign-in call had just answered.
  Future<void> signIn({Map<String, dynamic>? session}) async {
    await this.session.adopt(session ?? sessionJson());
  }
}
