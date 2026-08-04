# Myket in-app billing (com.github.myketstore:myket-billing-client).
#
# The AAR ships no consumer ProGuard rules of its own — verified by
# unpacking it — and release builds here run with isMinifyEnabled = true.
# Without these keeps, R8 is free to strip or rename the SDK's internals and
# billing breaks only in a signed release build, which is the worst possible
# place to find out.
#
# The AIDL stub is the sharpest edge: it is resolved through
# Stub.asInterface(IBinder) across a process boundary, and the broadcast
# fallback (BroadcastIAB / IABReceiver) addresses the SDK's own classes by
# name in intents — neither survives renaming.
-keep class ir.myket.billingclient.** { *; }
-keep interface ir.myket.billingclient.** { *; }
-keep class com.android.vending.billing.** { *; }

# Purchase / SkuDetails / IabResult are built from store JSON via their
# constructors and read back field-by-field on the Dart side.
-keepclassmembers class ir.myket.billingclient.util.** {
    public <init>(...);
    public *;
}
