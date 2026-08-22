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
        // La version la pone el CI (numero de corrida). Con versionCode fijo, Android se niega
        // a instalar una compilacion nueva encima de otra "de la misma version", y ademas seria
        // imposible saber que version corre cada celular.
        versionCode = (System.getenv("APK_VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("APK_VERSION_NAME") ?: "1.0.0-dev"
        // [MosGuard] UNA sola app. El paquete sigue siendo dev.levo.yapecaptor A PROPÓSITO: así cada
        // YapeCaptor ya instalado se ACTUALIZA a MosGuard con una actualización normal (Android solo
        // actualiza dentro del mismo paquete). Lo que cambia es la identidad de cara al usuario:
        // nombre "MosGuard" e ícono propio. Las capacidades de resguardo (GPS/cámara) están siempre
        // presentes; el dueño decide POR EQUIPO, desde MOS, qué captura Yapes y qué solo se resguarda.
        manifestPlaceholders["appLabel"] = "MosGuard"
        // [tamaño] La lib WebRTC nativa trae .so para 4 ABIs → APK de 43MB (se corta al bajar por datos →
        // "error de análisis del paquete"). Filtramos a las 2 ABIs que usan los celulares reales (arm64
        // modernos + armv7 viejos de zona); se van x86/x86_64 → APK ~mitad, descarga confiable.
        ndk { abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a")) }
        buildConfigField("boolean", "ES_GUARD", "true")
        buildConfigField("String", "TAG_PREFIX", "\"yape-v\"")
        buildConfigField("String", "APK_MATCH", "\"YapeCaptor\"")   // el asset del release sigue nombrándose YapeCaptor-*.apk (continuidad del auto-update)
    }
    buildFeatures { buildConfig = true }

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
    // [MosGuard · Spy 2.0 nativo] WebRTC nativo (libwebrtc, fork mantenido webrtc-sdk). Cámara/mic nativos
    // + PeerConnection sin WebView → video+audio en vivo desde un foreground service (EspiaNativo.kt).
    implementation("io.github.webrtc-sdk:android:114.5735.10")
}
