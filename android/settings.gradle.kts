pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.10.0"
}
dependencyResolutionManagement {
    @Suppress("UnstableApiUsage")
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        exclusiveContent {
            forRepository {
                ivy("https://github.com/k2-fsa/sherpa-onnx/releases/download") {
                    name = "sherpa-onnx releases"
                    patternLayout { artifact("v[revision]/[module]-[revision].[ext]") }
                    metadataSources { artifact() }
                }
            }
            filter { includeModule("com.k2fsa.sherpa.onnx", "sherpa-onnx-static-link-onnxruntime") }
        }
    }
}

rootProject.name = "Enve"
include(":app")
include(":core")
include(":engine-api")
include(":engine")
include(":hearth-ui")
include(":audiobookshelf")
include(":storyteller")
include(":komga")
include(":local")
include(":plex")
include(":bookorbit")
include(":silo")
include(":wear-protocol")
include(":wear")

if (providers.gradleProperty("enveWoofSource").isPresent) {
    include(":woof-runtime")
    project(":woof-runtime").projectDir = file("BuildSupport/WoofRuntime")
}
