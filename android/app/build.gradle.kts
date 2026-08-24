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
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
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
}
