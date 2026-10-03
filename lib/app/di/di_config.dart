import 'package:audio_io/audio_io.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/account/account_config.dart';
import '../../core/account/account_session.dart';
import '../../core/account/account_store.dart';
import '../../core/account/auth_repository.dart';
import '../../core/account/email_link.dart';
import '../../core/account/google_id_token_source.dart';
import '../../core/account/profile_sync.dart';
import '../../core/entitlement/bazaar_billing_service.dart';
import '../../core/entitlement/billing_service.dart';
import '../../core/entitlement/install_identity.dart';
import '../../core/entitlement/license_gate.dart';
import '../../core/entitlement/plan_catalog.dart';
import '../../core/entitlement/signed_entitlement.dart';
import '../../core/entitlement/http_subscription_remote.dart';
import '../../core/entitlement/subscription_remote.dart';
import '../../core/entitlement/subscription_service.dart';
import '../../core/locale/locale_service.dart';
import '../../core/security/app_secure_storage.dart';
import '../../core/network/api_client.dart';
import '../../core/network/authenticated_api_client.dart';
import '../../core/network/http_api_client.dart';
import '../../core/network/http_service_client.dart';
import '../../core/network/service_api.dart';
import '../../core/settings/settings_repository.dart';
import '../../feature/legal/data/legal_asset_source.dart';

import '../../feature/transfer/data/repository/bluetooth_transfer_repository.dart';
import '../../feature/transfer/data/repository/live_transfer_repository.dart';
import '../../feature/transfer/data/repository/webrtc_transfer_repository.dart';
import '../../feature/transfer/domain/repository/bluetooth_transport.dart';
import '../../feature/transfer/domain/repository/guest_link_controller.dart';
import '../../feature/transfer/domain/repository/transfer_repository.dart';
import '../../feature/transfer/domain/repository/wifi_transfer_repository.dart';
import '../../feature/transfer/domain/service/transfer_mode_store.dart';
import 'di_config.config.dart';

@injectableInit
Future<void> configureDependencies() async {
  await GetIt.instance.init();
}

@module
abstract class RegisterThirdParty {
  @lazySingleton
  AudioIo get audioIo => AudioIo.instance;

  /// Resolved exactly once, before the rest of the graph — everything that
  /// persists (SettingsRepository, TransferModeStore, the flow-flag writers)
  /// receives this instance instead of calling getInstance() itself.
  @preResolve
  Future<SharedPreferences> get prefs => SharedPreferences.getInstance();
}

@module
abstract class NetworkModule {
  /// One HTTP client for the whole process.
  ///
  /// Registered here rather than annotated on the class because
  /// [HttpApiClient] takes an optional `http.Client` as a test seam, which
  /// injectable would otherwise try to resolve out of the graph.
  ///
  /// The app makes two kinds of request through this, both for static files
  /// on tarkk.ir: whether a newer privacy policy or terms document has been
  /// published, and whether a newer app build is out (feature/update).
  /// Nothing about a conversation goes near it — see core/network.
  @lazySingleton
  ApiClient apiClient() => HttpApiClient();
}

@module
abstract class LegalModule {
  /// The documents bundled in the APK. Same reasoning as [NetworkModule]:
  /// the optional AssetBundle is a seam for tests.
  @lazySingleton
  LegalAssetSource legalAssetSource() => LegalAssetSource();
}

@module
abstract class BillingModule {
  /// Cafe Bazaar wherever the paid features are live (Android, monetized
  /// builds); the stub everywhere else, which has nothing to sell.
  @lazySingleton
  BillingService billingService() => Monetization.active
      ? BazaarBillingService()
      : const UnavailableBillingService();

  /// Keystore-backed on Android wherever the paid features or sign-in are
  /// live (AccountConfig.enabled covers both); memory-only elsewhere, where
  /// nothing is ever locked and nobody signs in.
  @lazySingleton
  AppSecureStorage appSecureStorage() => AccountConfig.enabled
      ? PlatformAppSecureStorage()
      : MemoryAppSecureStorage();

  @lazySingleton
  InstallIdentity installIdentity(AppSecureStorage storage) =>
      InstallIdentity(storage);

  /// The backend, on behalf of the signed-in account. Answers "signed out"
  /// without a request when nobody is.
  @lazySingleton
  SubscriptionRemote subscriptionRemote(AuthenticatedApiClient api) =>
      HttpSubscriptionRemote(api);

  /// Local subscription state belongs to the account that fetched it, so it
  /// is dropped whenever the session ends (sign-out, deletion, or the
  /// server ending it).
  @lazySingleton
  SubscriptionService subscriptionService(
    AppSecureStorage storage,
    InstallIdentity identity,
    SubscriptionRemote remote,
    AccountSession session,
  ) {
    final service = SubscriptionService(
      storage: storage,
      identity: identity,
      verifier: EntitlementVerifier(EntitlementKeys.fromEnvironment()),
      remote: remote,
      monetized: Monetization.active,
    );
    session.signedOut.listen((_) => service.clear());
    return service;
  }

  @lazySingleton
  LicenseGate licenseGate(SubscriptionService subscription) =>
      LicenseGateImpl(subscription);
}

@module
abstract class AccountModule {
  @lazySingleton
  AccountStore accountStore(AppSecureStorage storage) => AccountStore(storage);

  /// The backend client every account and subscription call goes through.
  /// Each call carries the platform and, where sign-in exists, this
  /// install's public key (the server stores both on the session).
  @lazySingleton
  TarkServiceClient tarkServiceClient(InstallIdentity identity) =>
      HttpTarkServiceClient(
        commonHeaders: () async {
          final platform = AccountConfig.platformHeader;
          final headers = <String, String>{
            'X-Tark-Platform': ?platform,
            // Every people-facing word the server sends (error messages,
            // plan names) follows the app's language, not the phone's.
            'Accept-Language': LocaleService.currentLocale.languageCode,
          };
          if (AccountConfig.enabled) {
            await identity.load();
            headers['X-Tark-Install-Key'] = identity.publicKey;
          }
          return headers;
        },
      );

  @lazySingleton
  PlanCatalog planCatalog(TarkServiceClient transport) =>
      PlanCatalog(transport);

  @lazySingleton
  AuthenticatedApiClient authenticatedApiClient(
    TarkServiceClient transport,
    AccountStore store,
  ) => AuthenticatedApiClient(transport, store);

  @lazySingleton
  AccountSession accountSession(
    AuthenticatedApiClient api,
    AccountStore store,
  ) => AccountSession(api: api, store: store, available: AccountConfig.enabled);

  @lazySingleton
  GoogleIdTokenSource googleIdTokenSource() => PlatformGoogleIdTokenSource(
    serverClientId: AccountConfig.googleServerClientId,
  );

  @lazySingleton
  AuthRepository authRepository(
    AccountSession session,
    AccountStore store,
    GoogleIdTokenSource google,
    SettingsRepository settings,
  ) => AuthRepository(
    session: session,
    store: store,
    google: google,
    localeCode: settings.getLocaleCode,
    localName: settings.getMyName,
  );

  @lazySingleton
  ProfileSync profileSync(
    AccountSession session,
    AccountStore store,
    SettingsRepository settings,
  ) => ProfileSync(session: session, store: store, settings: settings);

  @lazySingleton
  EmailLinkSource emailLinkSource() => AppLinksEmailLinkSource();

  @lazySingleton
  EmailLinkDispatcher emailLinkDispatcher() => EmailLinkDispatcher();
}

@module
abstract class TransferModule {
  BluetoothTransport bluetoothTransport(BluetoothTransferRepository impl) =>
      impl;

  GuestLinkController guestLinkController(WebRtcTransferRepository impl) =>
      impl;

  /// Session-scoped selector used by the live Walkie Cubit.
  ///
  /// The old provider picked a concrete repository once when the Cubit was
  /// created. A Room failover could then update [TransferModeStore.mode] while
  /// the already-running Cubit kept sending on that stale repository. Keep the
  /// Cubit stable instead and let [LiveTransferRepository] replace only the
  /// temporary transport attachment. Wi-Fi/hotspot still share the same live
  /// repository; Bluetooth and Guest reuse their already-connected singletons.
  TransferRepository transferRepository(
    TransferModeStore store,
    WifiTransferRepository wifi,
    BluetoothTransferRepository bluetooth,
    WebRtcTransferRepository webrtc,
  ) => LiveTransferRepository(
    modeStore: store,
    wifi: wifi,
    bluetooth: bluetooth,
    guest: webrtc,
  );
}
