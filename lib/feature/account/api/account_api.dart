/// Public surface of the account feature: the sign-in screens.
///
/// The app composition root routes to [SignInPage] (from the subscription
/// screen) and to [CodeEntryPage] (when an email link opens the app); the
/// Profile page's account card pushes the rest directly.
library;

export '../presentation/page/change_password_page.dart' show ChangePasswordPage;
export '../presentation/page/code_entry_page.dart' show CodeEntryPage;
export '../presentation/page/delete_account_page.dart' show DeleteAccountPage;
export '../presentation/page/sign_in_page.dart' show SignInPage;
export '../presentation/page/subscription_page.dart' show SubscriptionPage;
export '../presentation/widget/auth_widgets.dart'
    show pushAuthPage, showAuthToast;
