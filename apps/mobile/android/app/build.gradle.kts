import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "uk.drakon4ik.symbio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "uk.drakon4ik.symbio"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // One installable app per backend environment so a dev/staging build never
    // replaces the Play-installed prod app. The flavor only controls identity
    // (application id, launcher label); which backend the app talks to is
    // still --dart-define=APP_ENV, so the two must be passed together — use
    // the Makefile / workflow commands, not bare `flutter run`.
    // Each application id needs its own Android OAuth client (package name +
    // signing SHA-1) in the Google Cloud project or Google Sign-In fails.
    flavorDimensions += "env"
    productFlavors {
        create("local") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Symbio Dev")
        }
        create("staging") {
            dimension = "env"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            resValue("string", "app_name", "Symbio Staging")
        }
        create("prod") {
            dimension = "env"
            // Bare id — this is the Play Store / GitHub Releases app.
            resValue("string", "app_name", "Symbio")
        }
    }

    val keyPropertiesFile = rootProject.file("key.properties")
    if (keyPropertiesFile.exists()) {
        val keyProperties = Properties()
        keyProperties.load(FileInputStream(keyPropertiesFile))
        signingConfigs {
            create("release") {
                keyAlias = keyProperties["keyAlias"] as String
                keyPassword = keyProperties["keyPassword"] as String
                storeFile = file(keyProperties["storeFile"] as String)
                storePassword = keyProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keyPropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
