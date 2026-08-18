plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.levo.yapecaptor"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.levo.yapecaptor"
        minSdk = 24              // Android 7 — cubre los equipos viejos de las zonas
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // firmado con la clave de debug: es una app interna que se instala a mano,
            // no va a Play Store. Así el APK sale instalable directo del build de CI.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
