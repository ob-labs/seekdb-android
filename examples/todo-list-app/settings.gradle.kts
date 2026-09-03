pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // androidx.inspection (Database Inspector) is not on Maven Central; use AndroidX snapshot repo.
        maven {
            url = uri("https://androidx.dev/snapshots/builds/15127136/artifacts/repository")
            content { includeGroup("androidx.inspection") }
        }
    }
}

rootProject.name = "seekdb-todo-list-app"

include(":app")

// Build seekdb-android from source in this repository. The path is relative to this
// settings file (the repo root is two levels up), so no machine-specific path is committed.
// Once seekdb-android is published, remove this block and rely on the coordinates in
// app/build.gradle.kts (e.g. https://jitpack.io or Maven Central).
includeBuild("../..") {
    dependencySubstitution {
        substitute(module("com.oceanbase.seekdb:seekdb-android"))
            .using(project(":seekdb-android"))
        substitute(module("com.oceanbase.seekdb:seekdb-android-inspection"))
            .using(project(":seekdb-android-inspection"))
    }
}
