import '../locale/locale_service.dart';
import '../network/service_api.dart';
import '../utils/logger.dart';
import 'billing_service.dart';

/// The plans on sale, as the backend lists them (`GET /subscription/plans`),
/// with names in the app's language.
///
/// Kept for the life of the process per language: the list changes only
/// when the server's settings do, and a paywall opened twice should not
/// wait on the network twice. A failed load is not kept, so the next
/// paywall tries again.
class PlanCatalog {
  PlanCatalog(this._api, {String Function()? language})
    : _language = language ?? (() => LocaleService.currentLocale.languageCode);

  final TarkServiceClient _api;
  final String Function() _language;

  String? _cachedFor;
  List<BillingPlan>? _cached;
  Future<List<BillingPlan>>? _inFlight;

  /// Empty when the server could not be reached or answered with nothing
  /// usable; the paywall then says purchases are unavailable.
  Future<List<BillingPlan>> load() {
    final language = _language();
    final cached = _cached;
    if (cached != null && _cachedFor == language) return Future.value(cached);
    return _inFlight ??= () async {
      try {
        final response = await _api.send(
          ApiRequest.get(
            '/subscription/plans',
            headers: {'Accept-Language': language},
          ),
        );
        if (response is! ApiOk) {
          Logger.log('Subscription: plans unavailable ($response)');
          return const <BillingPlan>[];
        }
        final raw = response.body['plans'];
        final seen = <String>{};
        final plans = <BillingPlan>[
          if (raw is List)
            for (final entry in raw)
              if (BillingPlan.fromJson(entry) case final plan?
                  when seen.add(plan.sku))
                plan,
        ];
        if (plans.isNotEmpty) {
          _cached = plans;
          _cachedFor = language;
        }
        return plans;
      } finally {
        _inFlight = null;
      }
    }();
  }
}
