# Cafe Bazaar billing. Bazaar's security notes ask for the billing AIDL
# interface to survive shrinking, and Poolakey ships no consumer rules of its
# own, so keep both rather than find out on a release build.
-keep class com.android.vending.billing.** { *; }
-keep class ir.cafebazaar.poolakey.** { *; }
