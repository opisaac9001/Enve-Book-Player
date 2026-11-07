import java.security.MessageDigest
import java.util.zip.ZipFile

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("kotlin-parcelize")
    id("com.google.devtools.ksp")
    id("com.google.dagger.hilt.android")
}

val sherpaOnnx: Configuration by configurations.creating {
    isCanBeConsumed = false
    isTransitive = false
}
val sherpaOnnxSha256 = "07e042d97f3a6bd5b7fe74d4eef0513dc01a714b16c15a903250095aba43a575"
val sherpaOnnxDir = layout.buildDirectory.dir("generated/sherpaOnnx")
val extractSherpaOnnx = tasks.register("extractSherpaOnnx") {
    inputs.files(sherpaOnnx)
    inputs.property("sha256", sherpaOnnxSha256)
    outputs.dir(sherpaOnnxDir)
    doLast {
        val archive = sherpaOnnx.singleFile
        val digest = MessageDigest.getInstance("SHA-256")
        archive.inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val actual = digest.digest().joinToString("") { byte -> "%02x".format(byte) }
        check(actual == sherpaOnnxSha256) { "sherpa-onnx AAR digest mismatch: $actual" }

        ZipFile(archive).use { zip ->
            for (name in listOf("classes.jar", "jni/arm64-v8a/libsherpa-onnx-jni.so")) {
                val target = sherpaOnnxDir.get().file(name).asFile
                target.parentFile.mkdirs()
                zip.getInputStream(zip.getEntry(name)).use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            }
        }
    }
}

android {
    namespace = "com.enve.engine.impl"
    compileSdk { version = release(36) { minorApiLevel = 1 } }
    ndkVersion = "27.2.12479018"

    defaultConfig {
        minSdk = 26

        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    sourceSets.getByName("main").jniLibs.srcDir(
        files(sherpaOnnxDir.map { it.dir("jni") }).builtBy(extractSherpaOnnx)
    )

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    buildFeatures {
        buildConfig = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    api(project(":core"))
    api(project(":engine-api"))
    implementation(project(":audiobookshelf"))
    implementation(project(":storyteller"))
    implementation(project(":komga"))
    implementation(project(":local"))
    implementation(project(":plex"))
    implementation(project(":bookorbit"))
    implementation(project(":silo"))

    implementation("org.nanohttpd:nanohttpd:2.3.1")
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.24.2")
    sherpaOnnx("com.k2fsa.sherpa.onnx:sherpa-onnx-static-link-onnxruntime:2.0.1@aar")
    implementation(files(sherpaOnnxDir.map { it.file("classes.jar") }).builtBy(extractSherpaOnnx))

    implementation("com.google.dagger:hilt-android:2.58")
    ksp("com.google.dagger:hilt-compiler:2.58")

    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("androidx.hilt:hilt-work:1.2.0")
    ksp("androidx.hilt:hilt-compiler:1.2.0")

    implementation("androidx.paging:paging-runtime-ktx:3.3.5")

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

    implementation("io.coil-kt:coil:2.7.0")

    implementation("me.zhanghai.android.libarchive:library:1.1.6")

    implementation("androidx.media3:media3-exoplayer:1.10.0")
    implementation("androidx.media3:media3-session:1.10.0")
    implementation("androidx.media3:media3-ui:1.10.0")
    implementation("androidx.media3:media3-datasource-okhttp:1.10.0")
    implementation("androidx.media3:media3-cast:1.10.0")
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
    implementation("androidx.mediarouter:mediarouter:1.7.0")
    implementation("androidx.appcompat:appcompat:1.7.0")

    implementation("org.readium.kotlin-toolkit:readium-shared:3.3.0")
    implementation("org.readium.kotlin-toolkit:readium-streamer:3.3.0")
    implementation("org.readium.kotlin-toolkit:readium-navigator:3.3.0")
    implementation("androidx.fragment:fragment-ktx:1.8.5")

    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.health.connect:connect-client:1.1.0")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}

tasks.configureEach {
    if (
        name.startsWith("merge") && name.endsWith("JniLibFolders")
            || name.contains("lint", ignoreCase = true)
    ) {
        dependsOn(extractSherpaOnnx)
    }
}
