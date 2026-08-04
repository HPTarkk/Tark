import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget


plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}


val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
} else {
    println("key.properties not found, relying on environment variables or secrets.")
}

val releaseKeystorePassword = keystoreProperties.getProperty("storePassword") ?: System.getenv("KEYSTORE_PASSWORD")
val releaseKeyPassword = keystoreProperties.getProperty("keyPassword") ?: System.getenv("KEY_PASSWORD")
val releaseKeyAlias = keystoreProperties.getProperty("keyAlias") ?: System.getenv("KEY_ALIAS")
val releaseStoreFile = keystoreProperties.getProperty("storeFile") ?: "../upload-keystore.jks"


android {
    namespace = "com.b1101.tark"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Raised 17 -> 21 for myket_iap, which publishes Java 21 bytecode and
    // fails to link against a 17 target. Gradle already runs on Android
    // Studio's bundled JBR 21, so no extra JDK install is needed.
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_21)
        }
    }

    defaultConfig {
        applicationId = "com.b1101.tark"
        minSdk = flutter.minSdkVersion.toInt()
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Myket billing service coordinates. The plugin templates these into
        // its own manifest (permission + service bind), which is why the app
        // manifest needs no ir.mservices.market entries of its own. A Bazaar
        // flavor later overrides these three with Poolakey's equivalents.
        val marketApplicationId = "ir.mservices.market"
        manifestPlaceholders["marketApplicationId"] = marketApplicationId
        manifestPlaceholders["marketBindAddress"] =
            "$marketApplicationId.InAppBillingService.BIND"
        manifestPlaceholders["marketPermission"] = "$marketApplicationId.BILLING"
    }

    signingConfigs {
        create("release") {
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
            storePassword = releaseKeystorePassword
            storeFile = file(releaseStoreFile)
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            // Was minifying with no rules at all. The Myket billing AAR ships
            // no consumer rules, so its internals need explicit keeps or
            // billing breaks in release only — see proguard-rules.pro.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            signingConfig = null
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Myket's native billing SDK, talked to directly from BillingHandler.
    //
    // Not the myket_iap Flutter plugin: that wrapper only ever calls
    // IabHelper.launchPurchaseFlow(activity, sku, listener, payload), the
    // overload hardcoded to ITEM_TYPE_INAPP, so subscriptions are
    // unreachable through it. The SDK underneath exposes
    // launchSubscriptionPurchaseFlow — this app binds to that itself.
    implementation("com.github.myketstore:myket-billing-client:1.19")

    // Phone side of the Galaxy Watch companion. The watch and handheld use
    // MessageClient for low-latency room controls and status requests; voice
    // audio never enters the Data Layer.
    implementation("com.google.android.gms:play-services-wearable:20.0.1")
}
