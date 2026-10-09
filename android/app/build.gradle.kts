import java.util.Properties
import java.util.Base64
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
val isDeviceTestBuild = providers.gradleProperty("tarkDeviceTest").orNull == "true"

// Flutter forwards --dart-define and --dart-define-from-file as Base64 entries.
// Match Dart's Monetization flags so unlocked builds have no billing permission.
val dartDefines = providers.gradleProperty("dart-defines").orNull
    .orEmpty().split(',').filter { it.isNotEmpty() }.associate { encoded ->
        val entry = String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        val separator = entry.indexOf('=')
        require(separator > 0) { "Invalid Flutter dart-define" }
        entry.substring(0, separator) to entry.substring(separator + 1)
    }
val bazaarBillingEnabled = dartDefines["TARK_MONETIZED"] == "true" ||
    dartDefines["TARK_LOCK_PREMIUM"] == "true"


android {
    if (!bazaarBillingEnabled) {
        // Debug/profile overlays only repeat INTERNET, which main already has.
        // Use this higher-priority overlay for every unlocked Android build.
        sourceSets.configureEach {
            if (name in setOf("debug", "profile", "release")) {
                manifest.srcFile("src/unmonetized/AndroidManifest.xml")
            }
        }
    }
    namespace = "com.b1101.tark"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

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
        // Flutter's default (36 on 3.47) is what ships. The floor keeps an
        // older Flutter SDK on some machine from ever building below 34.
        targetSdk = maxOf(flutter.targetSdkVersion, 34)
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
        getByName("debug") {
            // Device-test APKs are intentionally a separate app so they can be
            // installed from GitHub Actions without the production signing key
            // and without replacing/deleting the user's installed Tark build.
            if (isDeviceTestBuild) {
                applicationIdSuffix = ".dev"
                versionNameSuffix = "-device-test"
            }
        }
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // FileProvider, for handing an exported diagnostic log to the share sheet
    // as a content:// URI (see DiagnosticsHandler). The Flutter embedding
    // already pulls androidx.core in transitively; declaring it explicitly
    // means the class we compile against is a stated dependency rather than an
    // accident of someone else's transitive graph. Gradle resolves conflicts
    // to the highest version, so this cannot downgrade the embedding's copy.
    implementation("androidx.core:core:1.13.1")

    // Cafe Bazaar in-app billing (see billing/BazaarBillingHandler). Served
    // from JitPack only; see the exclusiveContent block in ../build.gradle.kts.
    implementation("com.github.cafebazaar.Poolakey:poolakey:2.2.0")
}
