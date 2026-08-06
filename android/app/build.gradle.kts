plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.felicedesign.stepcounter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.felicedesign.stepcounter"
        // 26 is the floor for the notification-channel APIs the foreground
        // service relies on.
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // A committed keystore with a published password, on purpose.
        //
        // This app is distributed as a sideloaded APK from CI, so the previous
        // arrangement signed release builds with the *debug* key. That looked
        // equivalent — the debug key's password is public too — but it was not:
        // the debug keystore is generated on first use, and CI runners are
        // ephemeral, so every build produced an APK signed by a brand new key.
        // Android refuses to install an update signed by a different key, so
        // every release had to be installed over an uninstall, taking the step
        // history and every calibration test with it.
        //
        // A fixed key makes updates actual updates. It grants no secrecy and is
        // not meant to: anyone with this repo can sign an APK that claims this
        // application id, exactly as they could when the debug key was used.
        // Publishing to Play would need a real secret-held key; sideloading a
        // personal build does not.
        create("sideload") {
            storeFile = file("../sideload.jks")
            storePassword = "sideload"
            keyAlias = "sideload"
            keyPassword = "sideload"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("sideload")
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")

    // DetectionGoldenTest pins the Kotlin detector to the same golden fixtures
    // the Dart tests use, so the live and replay implementations cannot drift.
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
