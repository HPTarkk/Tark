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
    // myket-billing-client is published on jitpack only.
    maven { setUrl("https://jitpack.io") }
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

// These two read/write the android extension through the concrete DSL
// interfaces rather than CommonExtension: CommonExtension lost both its type
// parameters and its compileSdk property in AGP 9, so no single spelling of it
// compiles against 8.x and 9.x. ApplicationExtension/LibraryExtension are
// stable across both.
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

fun Project.raiseCompileSdkToApp() {
    val appCompileSdk = project(":app").androidCompileSdk() ?: return
    val ownCompileSdk = androidCompileSdk() ?: return
    if (ownCompileSdk < appCompileSdk) {
        logger.lifecycle("Raising :$name compileSdk $ownCompileSdk -> $appCompileSdk (AGP 9 AAR metadata check)")
        setAndroidCompileSdk(appCompileSdk)
    }
}

// AGP 9 turned the AAR-metadata compileSdk check into a hard error, so a plugin
// pinning an old compileSdk now fails the whole build instead of warning:
// adtrace_sdk_flutter pins 33, while androidx.fragment 1.7.1 (pulled in
// transitively) declares minCompileSdk 34. Raise any Android subproject sitting
// below the app's compileSdk up to it — compileSdk only widens the API surface a
// module compiles against, and minSdk/targetSdk are untouched, so this cannot
// change what the plugin runs on.
subprojects {
    // The evaluationDependsOn(":app") above evaluates :app eagerly, so by the
    // time this loop reaches it afterEvaluate is no longer accepted.
    if (state.executed) raiseCompileSdkToApp() else afterEvaluate { raiseCompileSdkToApp() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
