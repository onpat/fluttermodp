allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// flutter_pcm_sound 3.3.3 declares compileSdk 33, while the AndroidX versions
// used by the current Flutter embedding require API 34 or newer. Override only
// Android library modules at project level; this does not change min/target SDK.
subprojects {
    afterEvaluate {
        if (name == "flutter_pcm_sound" && plugins.hasPlugin("com.android.library")) {
            extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                compileSdk = 36
            }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
