import java.security.MessageDigest

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
val generatedLegalAssets = layout.buildDirectory.dir("generated/legal/assets")
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

val generateLegalAssets = tasks.register<Sync>("generateLegalAssets") {
    into(generatedLegalAssets.map { it.dir("licenses") })

    from(rootProject.file("LICENSE.md")) { rename { "enve-LICENSE.txt" } }
    from(rootProject.file("NOTICE.md")) { rename { "enve-NOTICE.txt" } }
    from(rootProject.file("THIRD_PARTY_NOTICES.md")) { rename { "THIRD_PARTY_NOTICES.txt" } }
    from(rootProject.file("engine/src/main/cpp/libmobi/COPYING")) { rename { "libmobi-LGPL-3.0.txt" } }
    from(rootProject.file("engine/src/main/cpp/libmobi/PROVENANCE.md")) { rename { "libmobi-PROVENANCE.txt" } }
    from(rootProject.file("engine/src/main/cpp/whisper/LICENSE")) { rename { "whisper-MIT.txt" } }
    from(rootProject.file("engine/src/main/cpp/whisper/PROVENANCE.md")) { rename { "whisper-PROVENANCE.txt" } }
    from(rootProject.file("BuildSupport/Jcifs/LICENSE.txt")) { rename { "jcifs-ng-LGPL-2.1.txt" } }
    from(rootProject.file("BuildSupport/Jcifs/UPSTREAM.txt")) { rename { "jcifs-ng-UPSTREAM.txt" } }
    from(rootProject.file("BuildSupport/Licenses/Apache-2.0.txt")) { rename { "Qwen3-0.6B-LICENSE.txt" } }
    from(rootProject.file("BuildSupport/Models/UPSTREAM.md")) { rename { "downloadable-models-UPSTREAM.txt" } }
    from(rootProject.file("BuildSupport/ProviderLogos/PROVENANCE.md")) { rename { "provider-logos-PROVENANCE.txt" } }
    from(rootProject.file("BuildSupport/Licenses/Apache-2.0.txt")) { rename { "pdf.js-Apache-2.0.txt" } }
    from(rootProject.file("ThirdParty/foliate-js/vendor/pdfjs/cmaps/LICENSE")) { rename { "pdf.js-CMaps-BSD.txt" } }
    from(rootProject.file("ThirdParty/foliate-js/vendor/pdfjs/standard_fonts/LICENSE_FOXIT")) { rename { "pdf.js-Foxit-fonts-BSD.txt" } }
    from(rootProject.file("ThirdParty/foliate-js/vendor/pdfjs/standard_fonts/LICENSE_LIBERATION")) { rename { "pdf.js-Liberation-fonts-OFL-1.1.txt" } }
    from(rootProject.file("ThirdParty/grimmory-branding/LICENSE")) { rename { "grimmory-MIT.txt" } }
    from(rootProject.file("ThirdParty/grimmory-branding/ASSET-LICENSE.md")) { rename { "grimmory-ASSET-LICENSE.txt" } }
    from(rootProject.file("ThirdParty/grimmory-branding/TRADEMARKS.md")) { rename { "grimmory-TRADEMARKS.txt" } }
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
        versionCode = 46
        versionName = "1.2 build 46"
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
    sourceSets.getByName("main").assets.srcDir(
        files(generatedLegalAssets).builtBy(generateLegalAssets)
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

    implementation("androidx.media3:media3-exoplayer:1.11.0")
    implementation("androidx.media3:media3-session:1.11.0")
    implementation("androidx.media3:media3-ui:1.11.0")

    implementation("androidx.media3:media3-datasource-okhttp:1.11.0")

    implementation("androidx.media3:media3-cast:1.11.0")
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
        dependsOn(generateLegalAssets)
    }
    if (name.startsWith("check") && name.endsWith("Classpath")) {
        enabled = false
    }
}

val releaseDependencyInventory = layout.buildDirectory.file("reports/release/dependencies.tsv")

tasks.register("generateReleaseDependencyInventory") {
    outputs.file(releaseDependencyInventory)
    doLast {
        val releaseRuntimeClasspath = configurations.getByName("releaseRuntimeClasspath")
        val artifacts = releaseRuntimeClasspath.incoming.artifactView {
            componentFilter { identifier ->
                identifier is org.gradle.api.artifacts.component.ModuleComponentIdentifier
            }
        }.artifacts.artifacts
            .sortedBy { "${it.id.componentIdentifier}:${it.file.name}" }
        val lines = buildList {
            add("component\tartifact\tsha256")
            for (artifact in artifacts) {
                val digest = MessageDigest.getInstance("SHA-256")
                artifact.file.inputStream().buffered().use { input ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                    }
                }
                val sha256 = digest.digest().joinToString("") { byte: Byte -> "%02x".format(byte) }
                add("${artifact.id.componentIdentifier}\t${artifact.file.name}\t$sha256")
            }
        }
        releaseDependencyInventory.get().asFile.apply {
            parentFile.mkdirs()
            writeText(lines.joinToString("\n", postfix = "\n"))
        }
    }
}

tasks.register("verifyAcknowledgementsInventory") {
    inputs.file("src/main/res/raw/aboutlibraries.json")
    doLast {
        val releaseRuntimeClasspath = configurations.getByName("releaseRuntimeClasspath")
        val resolved = releaseRuntimeClasspath.incoming.resolutionResult.allComponents
            .mapNotNull { component ->
                val id = component.id as? org.gradle.api.artifacts.component.ModuleComponentIdentifier
                id?.let { "${it.group}:${it.module}" }
            }
            .toSet()
        val inventoryText = file("src/main/res/raw/aboutlibraries.json").readText()
        val missing = resolved.filterNot { coordinate ->
            listOf(coordinate, "$coordinate-android", "$coordinate-jvm")
                .any { candidate -> inventoryText.contains("\"uniqueId\":\"$candidate\"") }
        }.sorted()
        check(missing.isEmpty()) {
            "The in-app acknowledgements inventory is missing release dependencies:\n${missing.joinToString("\n")}"
        }
    }
}
