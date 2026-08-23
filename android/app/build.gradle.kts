plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("kotlin-parcelize")
    id("com.google.devtools.ksp")
    id("com.google.dagger.hilt.android")
}

val foliateSource = rootProject.layout.projectDirectory.dir("ThirdParty/foliate-js")
val foliateMetadata = rootProject.layout.projectDirectory.dir("BuildSupport/FoliateRuntime")
val generatedFoliateAssets = layout.buildDirectory.dir("generated/foliateRuntime/assets")
val foliateRuntimeFiles = listOf(
    "view.js",
    "epub.js",
    "epubcfi.js",
    "progress.js",
    "overlayer.js",
    "text-walker.js",
    "search.js",
    "tts.js",
    "footnotes.js",
    "vendor/zip.js",
)
val patchedFoliateRuntimeFiles = listOf(
    "fixed-layout.js",
    "paginator.js",
)

val generateFoliateRuntimeAssets = tasks.register<Sync>("generateFoliateRuntimeAssets") {
    into(generatedFoliateAssets)

    from(foliateSource) {
        include(*foliateRuntimeFiles.toTypedArray())
        into("foliate")
    }
    from(foliateSource) {
        include(*patchedFoliateRuntimeFiles.toTypedArray())
        into("foliate")
        filter { line: String ->
            when {
                line.contains("`allow-scripts` is needed") -> ""
                line.contains("bugs.webkit.org/show_bug.cgi?id=218086") -> ""
                else -> line.replace(
                    "allow-same-origin allow-scripts",
                    "allow-same-origin"
                )
            }
        }
    }
    from(foliateSource.file("LICENSE")) {
        into("licenses")
        rename { "foliate-LICENSE.txt" }
    }
    from(foliateMetadata) {
        include("UPSTREAM.txt", "zip.js-LICENSE.txt")
        into("licenses")
    }

    doFirst {
        check(foliateSource.file("view.js").asFile.isFile) {
            "Foliate submodule is missing. Run git submodule update --init --recursive."
        }
    }
    doLast {
        val expected = (
            foliateRuntimeFiles.map { "foliate/$it" }
                + patchedFoliateRuntimeFiles.map { "foliate/$it" }
                + listOf(
                    "licenses/foliate-LICENSE.txt",
                    "licenses/UPSTREAM.txt",
                    "licenses/zip.js-LICENSE.txt",
                )
            ).toSet()
        val destination = generatedFoliateAssets.get().asFile
        val actual = destination.walkTopDown()
            .filter(File::isFile)
            .map { it.relativeTo(destination).invariantSeparatorsPath }
            .toSet()
        check(actual == expected) {
            "Generated Foliate runtime does not match its allowlist."
        }
        for (file in patchedFoliateRuntimeFiles) {
            check(!destination.resolve("foliate/$file").readText().contains("allow-scripts")) {
                "Publication scripts must remain disabled in $file."
            }
        }
    }
}

android {
    namespace = "com.enve.app"
    compileSdk { version = release(36) { minorApiLevel = 1 } }
    buildToolsVersion = "35.0.0"
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "com.enve.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 44
        versionName = "1.2 build 44"
        buildConfigField(
            "String",
            "SOURCE_PROVENANCE",
            "\"enve-android-source-cc91a725-7756-4324-a504-e063bcecbfe0\"",
        )

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isDebuggable = true
            applicationIdSuffix = ".debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    sourceSets.getByName("main").assets.srcDir(
        files(generatedFoliateAssets).builtBy(generateFoliateRuntimeAssets)
    )

    packaging {
        resources {

            pickFirsts += "META-INF/nanohttpd/mimetypes.properties"
            pickFirsts += "META-INF/nanohttpd/default-mimetypes.properties"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {

    implementation(project(":core"))
    implementation(project(":engine-api"))
    implementation(project(":engine"))
    implementation(project(":hearth-ui"))
    implementation(project(":audiobookshelf"))
    implementation(project(":storyteller"))
    implementation(project(":komga"))
    implementation(project(":local"))
    implementation(project(":plex"))
    implementation(project(":bookorbit"))
    implementation(project(":silo"))
    implementation(project(":wear-protocol"))

    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    implementation("org.nanohttpd:nanohttpd:2.3.1")

    val composeBom = platform("androidx.compose:compose-bom:2025.08.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.compose.foundation:foundation")

    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.core:core-splashscreen:1.0.1")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("androidx.glance:glance-appwidget:1.1.1")

    implementation("androidx.navigation:navigation-compose:2.8.5")

    implementation("com.google.dagger:hilt-android:2.58")
    ksp("com.google.dagger:hilt-compiler:2.58")
    implementation("androidx.hilt:hilt-navigation-compose:1.2.0")

    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("androidx.hilt:hilt-work:1.2.0")
    ksp("androidx.hilt:hilt-compiler:1.2.0")

    implementation("androidx.paging:paging-runtime-ktx:3.3.5")
    implementation("androidx.paging:paging-compose:3.3.5")

    implementation("androidx.room:room-runtime:2.8.4")
    implementation("androidx.room:room-ktx:2.8.4")
    ksp("androidx.room:room-compiler:2.8.4")

    implementation("com.squareup.retrofit2:retrofit:2.11.0")
    implementation("com.squareup.retrofit2:converter-kotlinx-serialization:2.11.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jsoup:jsoup:1.17.2")
    implementation("eu.agno3.jcifs:jcifs-ng:2.1.10")

    implementation("com.google.mlkit:genai-prompt:1.0.0-beta2")
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.8.0")

    implementation("io.coil-kt:coil-compose:2.7.0")

    implementation("me.zhanghai.android.libarchive:library:1.1.6")

    implementation("androidx.media3:media3-exoplayer:1.10.0")
    implementation("androidx.media3:media3-session:1.10.0")
    implementation("androidx.media3:media3-ui:1.10.0")

    implementation("androidx.media3:media3-datasource-okhttp:1.10.0")

    implementation("androidx.media3:media3-cast:1.10.0")
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
    implementation("com.google.android.gms:play-services-wearable:20.0.1")
    implementation("androidx.mediarouter:mediarouter:1.7.0")

    implementation("androidx.appcompat:appcompat:1.7.0")

    implementation("com.android.billingclient:billing:9.1.0")

    implementation("androidx.datastore:datastore-preferences:1.1.1")

    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    implementation("org.readium.kotlin-toolkit:readium-shared:3.3.0")
    implementation("org.readium.kotlin-toolkit:readium-streamer:3.3.0")
    implementation("org.readium.kotlin-toolkit:readium-navigator:3.3.0")

    implementation("androidx.fragment:fragment-ktx:1.8.5")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}

tasks.configureEach {
    if (
        name.startsWith("merge") && name.endsWith("Assets")
            || name.contains("lint", ignoreCase = true)
    ) {
        dependsOn(generateFoliateRuntimeAssets)
    }
    if (name.startsWith("check") && name.endsWith("Classpath")) {
        enabled = false
    }
}
