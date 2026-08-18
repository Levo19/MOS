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

    // CLAVE DE FIRMA ESTABLE. Android se niega a instalar una actualización si viene firmada
    // con otra clave que la instalada. La clave de depuración se genera NUEVA en cada máquina y
    // en cada corrida de CI, así que firmar con ella obligaría a DESINSTALAR el equipo en cada
    // actualización — perdiendo el emparejamiento. Esta clave vive en el repo (la crea el propio
    // CI la primera vez) y no cambia nunca: las actualizaciones se instalan encima y el celular
    // conserva su secreto.
    signingConfigs {
        create("estable") {
            storeFile = file("../keystore/yape.jks")
            storePassword = "yapecaptor"
            keyAlias = "yape"
            keyPassword = "yapecaptor"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (file("../keystore/yape.jks").exists())
                signingConfigs.getByName("estable") else signingConfigs.getByName("debug")
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
