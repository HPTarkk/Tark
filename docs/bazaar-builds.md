# Bazaar build options

Android release builds ship with account access enabled and subscriptions
disabled. Billing permission is omitted and features are unlocked. An
ordinary `flutter build appbundle --release` uses these defaults.

If your defines file already enables billing, override both switches explicitly:

```shell
flutter build appbundle --release --dart-define-from-file=billing.json --dart-define=TARK_ACCOUNTS=true --dart-define=TARK_MONETIZED=false --dart-define=TARK_LOCK_PREMIUM=false
```

For a later release with subscriptions and Bazaar billing permission:

```shell
flutter build appbundle --release --dart-define-from-file=billing.json --dart-define=TARK_MONETIZED=true
```

`TARK_LOCK_PREMIUM=true` is also a subscription-enabled build: it forces locked
features for testing the subscription screens. Leave it false for distribution.
`TARK_ACCOUNTS=false` disables account access and checkout on Android.
Android reads the same Flutter defines as Dart, including defines loaded from
a file, so permission and subscription UI are controlled together in debug,
profile and release builds. Rebuild and reinstall after changing either flag.
