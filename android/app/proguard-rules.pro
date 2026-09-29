# Cafe Bazaar billing. Bazaar's security notes ask for the billing AIDL
# interface to survive shrinking, and Poolakey ships no consumer rules of its
# own, so keep both rather than find out on a release build.
-keep class com.android.vending.billing.** { *; }
-keep class ir.cafebazaar.poolakey.** { *; }

# Google sign-in (accounts) goes through Credential Manager, which finds its
# Play-services provider by reflection. Android's Credential Manager guide
# asks for this rule on minified builds.
-if class androidx.credentials.CredentialManager
-keep class androidx.credentials.playservices.** {
  *;
}
