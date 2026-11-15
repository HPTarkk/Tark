import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/entitlement/signed_entitlement.dart';

import 'token_factory.dart';

void main() {
  final issued = DateTime.utc(2026, 10, 1);
  final until = DateTime.utc(2026, 11, 1);
  late TokenFactory factory;
  late EntitlementVerifier verifier;

  setUp(() async {
    factory = await TokenFactory.create();
    verifier = EntitlementVerifier(factory.keys);
  });

  Future<SignedEntitlement?> verify(String raw, {String ik = 'install'}) =>
      verifier.verify(raw, expectedInstallKey: ik);

  test('a correctly signed token parses every field', () async {
    final raw = await factory.sign(
      TokenFactory.payload(issuedAt: issued, until: until, suspicious: true),
    );
    final token = await verify(raw);

    expect(token, isNotNull);
    expect(token!.status, EntitlementStatus.active);
    expect(token.until, until);
    expect(token.issuedAt, issued);
    expect(token.autoRenewing, isTrue);
    expect(token.suspicious, isTrue);
    expect(token.policy.grace, const Duration(hours: 72));
    expect(token.policy.refreshWindow, const Duration(days: 5));
    expect(token.raw, raw);
  });

  test('editing the payload breaks the signature', () async {
    final raw = await factory.sign(
      TokenFactory.payload(issuedAt: issued, until: until),
    );
    final parts = raw.split('.');
    final payload =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[2]))))
            as Map<String, dynamic>;
    payload['until'] = DateTime.utc(2099).millisecondsSinceEpoch;
    parts[2] = base64Url
        .encode(utf8.encode(jsonEncode(payload)))
        .replaceAll('=', '');

    expect(await verify(parts.join('.')), isNull);
  });

  test('a token signed by an unknown key is refused', () async {
    final other = await TokenFactory.create();
    final raw = await other.sign(
      TokenFactory.payload(issuedAt: issued, until: until),
    );
    expect(await verify(raw), isNull);
  });

  test('a token for a different install is refused', () async {
    final raw = await factory.sign(
      TokenFactory.payload(issuedAt: issued, until: until),
    );
    expect(await verify(raw, ik: 'another-phone'), isNull);
  });

  test('policy numbers outside the contract bounds are refused', () async {
    final raw = await factory.sign(
      TokenFactory.payload(issuedAt: issued, until: until, graceH: 10000),
    );
    expect(await verify(raw), isNull);
  });

  test('a paid status without an end date is refused', () async {
    final raw = await factory.sign(TokenFactory.payload(issuedAt: issued));
    expect(await verify(raw), isNull);
  });

  test('garbage is refused, not thrown', () async {
    expect(await verify(''), isNull);
    expect(await verify('v1.k1.%%%.@@@'), isNull);
    expect(await verify('v2.k1.a.b'), isNull);
    expect(await verify('x' * 5000), isNull);
  });

  test('keys parse from the build-time define', () {
    final encoded = base64Url.encode(factory.publicKey).replaceAll('=', '');
    final keys = EntitlementKeys.parse('k1:$encoded, bad:zz ,:x');
    expect(keys.keys, ['k1']);
    expect(keys['k1'], factory.publicKey);
    expect(EntitlementKeys.parse(''), isEmpty);
  });
}
