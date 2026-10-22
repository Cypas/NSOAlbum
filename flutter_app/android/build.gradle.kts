allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val isolatedBuildDir = System.getenv("NSO_GRADLE_BUILD_DIR")
val newBuildDir: Directory = if (isolatedBuildDir.isNullOrBlank()) {
    rootProject.layout.buildDirectory.dir("../../build").get()
} else {
    rootProject.layout.dir(rootProject.provider { rootProject.file(isolatedBuildDir) }).get()
}
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    if (name == "flutter_inappwebview_android") {
        apply(from = rootProject.file("webview_agp_compat.gradle"))
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
