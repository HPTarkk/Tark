/// Where the guest PWA is hosted (any static HTTPS host — GitHub Pages
/// works). The invite QR encodes `<this url>#o=<offer>` so scanning it with
/// a phone camera opens the join page with the connection offer embedded;
/// no server ever participates in signaling or audio.
///
/// Override at build time with:
///   flutter build apk --dart-define=GUEST_APP_URL=https://your.host/tark/
const kGuestWebAppUrl = String.fromEnvironment(
  'GUEST_APP_URL',
  defaultValue: 'https://p-b1101.github.io/tark/',
);
