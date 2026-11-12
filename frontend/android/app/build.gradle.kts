plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Reads google-services.json, wires Firebase config into the app build.
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.gms_new"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications — without this,
        // the release build fails at the AAR metadata check with
        // "requires core library desugaring to be enabled".
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.gms_new"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Renames the built APK to GMS-v<version>.apk (e.g. GMS-v1.0.0.apk)
    // instead of Flutter's generic app-release.apk — the version comes
    // straight from pubspec.yaml's `version:` line, so bumping that one
    // line is still the only place you ever need to edit.
    applicationVariants.all {
        outputs.all {
            val output = this as com.android.build.gradle.internal.api.BaseVariantOutputImpl
            output.outputFileName = "GMS-v${flutter.versionName}.apk"
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required alongside isCoreLibraryDesugaringEnabled above —
    // both are needed together, one alone isn't enough.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
