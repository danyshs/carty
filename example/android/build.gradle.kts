allprojects {
    repositories {
        google()
        mavenCentral()
    }
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

// Keep every plugin (library) module on the same compileSdk as the app module
// (which pins 36 directly), forcing it AFTER each module configures itself so
// our value wins over the sometimes-lagging Flutter default. Originally required
// by file_picker's transitive flutter_plugin_android_lifecycle; file_picker has
// since been replaced by file_selector, but the alignment guard is kept so no
// plugin module silently drifts to an older SDK. We skip ":app" here because
// evaluationDependsOn(":app") above already evaluated it — registering another
// afterEvaluate on it would throw "already evaluated".
subprojects {
    if (project.name != "app") {
        project.afterEvaluate {
            (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
                ?.compileSdkVersion(36)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
