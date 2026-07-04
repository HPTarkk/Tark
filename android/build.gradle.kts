// Mirrors FIRST: dl.google.com and repo.maven refuse downloads from this
// network, and every Flutter plugin's own buildscript pins its own AGP
// version (flutter_webrtc → 8.1.0, bluetooth_low_energy → 8.9.1, ...), so
// resolution must work without a VPN. Aliyun is the same mirror family as
// the flutter-io.cn storage this machine already uses; Myket is the
// Iranian fallback.
val configureMirrors: RepositoryHandler.() -> Unit = {
    maven { setUrl("https://maven.aliyun.com/repository/google") }
    maven { setUrl("https://maven.aliyun.com/repository/central") }
    maven { setUrl("https://maven.myket.ir") }
    google()
    mavenCentral()
}

allprojects {
    repositories.configureMirrors()
    // Plugin subprojects resolve their buildscript classpath (their pinned
    // AGP) from their OWN buildscript repositories — inject the mirrors
    // there too, before those projects get evaluated.
    buildscript.repositories.configureMirrors()
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
