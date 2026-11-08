// Official repositories first, regional mirrors as fallbacks.
//
// Some development networks cannot reach dl.google.com / Maven Central, so
// Aliyun and Myket remain important fallbacks. Putting a mirror first, however,
// makes a transient mirror outage fail CI even when the authoritative source is
// healthy. Gradle already falls through repository entries on an unavailable
// artifact, so official-first gives CI the stable path while preserving the
// existing no-VPN development fallback.
val configureRepositories: RepositoryHandler.() -> Unit = {
    google()
    mavenCentral()
    maven { setUrl("https://maven.aliyun.com/repository/google") }
    maven { setUrl("https://maven.aliyun.com/repository/central") }
    maven { setUrl("https://maven.myket.ir") }
    // Poolakey (Cafe Bazaar billing) is published only on JitPack. JitPack
    // builds whatever a GitHub repo tags, so it may serve Poolakey's group and
    // nothing else, and nothing else may resolve from it.
    exclusiveContent {
        forRepository { maven { setUrl("https://jitpack.io") } }
        filter { includeGroup("com.github.cafebazaar.Poolakey") }
    }
}

allprojects {
    repositories.configureRepositories()
    // Plugin subprojects resolve their buildscript classpath (their pinned
    // AGP) from their OWN buildscript repositories. Inject the same ordered
    // list before those projects are evaluated.
    buildscript.repositories.configureRepositories()
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Read/write Android SDK floors through the concrete DSL interfaces rather
// than CommonExtension. CommonExtension changed shape in AGP 9, while these two
// public extension types are stable across the AGP versions used by Tarkk's
// plugins.
fun Project.androidCompileSdk(): Int? =
    when (val ext = extensions.findByName("android")) {
        is com.android.build.api.dsl.ApplicationExtension -> ext.compileSdk
        is com.android.build.api.dsl.LibraryExtension -> ext.compileSdk
        else -> null
    }

fun Project.setAndroidCompileSdk(value: Int) {
    when (val ext = extensions.findByName("android")) {
        is com.android.build.api.dsl.ApplicationExtension -> ext.compileSdk = value
        is com.android.build.api.dsl.LibraryExtension -> ext.compileSdk = value
        else -> Unit
    }
}

fun Project.androidMinSdk(): Int? =
    when (val ext = extensions.findByName("android")) {
        is com.android.build.api.dsl.ApplicationExtension -> ext.defaultConfig.minSdk
        is com.android.build.api.dsl.LibraryExtension -> ext.defaultConfig.minSdk
        else -> null
    }

fun Project.setAndroidMinSdk(value: Int) {
    when (val ext = extensions.findByName("android")) {
        is com.android.build.api.dsl.ApplicationExtension -> ext.defaultConfig.minSdk = value
        is com.android.build.api.dsl.LibraryExtension -> ext.defaultConfig.minSdk = value
        else -> Unit
    }
}

// Flutter's default compileSdk, read from the Flutter Gradle extension that
// :app applies (the class lives in Flutter's included build, hence reflection).
fun Project.flutterDefaultCompileSdk(): Int? =
    extensions.findByName("flutter")?.let { ext ->
        runCatching { ext.javaClass.getMethod("getCompileSdkVersion").invoke(ext) as Int }
            .getOrNull()
    }

fun Project.alignAndroidSdkFloorsWithApp() {
    val app = project(":app")
    val appCompileSdk = app.androidCompileSdk()
    // Plugins are raised to Flutter's default compileSdk, never to a higher
    // one the app opts into: each new SDK's android.jar adds nullability
    // annotations, and Kotlin plugins written against the previous SDK stop
    // compiling (bluetooth_low_energy_android 6.2.1 does on API 37). A plugin
    // compiled against a lower SDK than the app is fine; one compiled against
    // a lower SDK than it was written for is not, so only stale ones move.
    val pluginCompileSdkFloor =
        listOfNotNull(appCompileSdk, app.flutterDefaultCompileSdk()).minOrNull()
    val ownCompileSdk = androidCompileSdk()
    if (pluginCompileSdkFloor != null && ownCompileSdk != null && ownCompileSdk < pluginCompileSdkFloor) {
        logger.lifecycle(
            "Raising :$name compileSdk $ownCompileSdk -> $pluginCompileSdkFloor (Tarkk plugin floor)",
        )
        setAndroidCompileSdk(pluginCompileSdkFloor)
    }

    // NDK 27 rejects native modules below API 21. More importantly, a plugin
    // embedded in Tarkk cannot actually support an Android version below the
    // application that owns it. Align stale plugin minSdk declarations with
    // Tarkk's real application floor instead of suppressing the NDK safety
    // check; targetSdk remains untouched.
    val appMinSdk = app.androidMinSdk()
    val ownMinSdk = androidMinSdk()
    if (appMinSdk != null && ownMinSdk != null && ownMinSdk < appMinSdk) {
        logger.lifecycle(
            "Raising :$name minSdk $ownMinSdk -> $appMinSdk (Tarkk app floor)",
        )
        setAndroidMinSdk(appMinSdk)
    }
}

// AGP 9 turned several SDK compatibility warnings into hard configuration
// errors. Some Flutter plugins pin older compile/min SDK values even though they
// are consumed only inside Tarkk, whose application floor is already higher.
// Align those module declarations with the app. This widens compile visibility
// and raises only an impossible-to-reach plugin-local minSdk; it never changes
// Tarkk's own supported Android range or any targetSdk behavior.
subprojects {
    // evaluationDependsOn(":app") above evaluates :app eagerly, so by the time
    // this loop reaches it afterEvaluate is no longer accepted.
    if (state.executed) {
        alignAndroidSdkFloorsWithApp()
    } else {
        afterEvaluate { alignAndroidSdkFloorsWithApp() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
