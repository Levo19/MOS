package dev.levo.yapecaptor

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * ACTUALIZACIÓN ASISTIDA.
 *
 * Lo que Android SÍ permite y lo que NO, dicho claro:
 *   · SÍ: que la app se entere de que hay una versión nueva, la descargue sola y abra el
 *     instalador con un toque.
 *   · NO: instalarla en silencio. Fuera de Play Store o de un equipo administrado por la
 *     empresa, Android SIEMPRE muestra su propia pantalla de confirmación. Ningún truco la
 *     evita, y está bien que sea así.
 *
 * O sea: el celular no hay que perseguirlo, pero alguien tiene que tocar "Instalar" una vez.
 *
 * De dónde sale la versión: del Release público del repo. Sin claves ni secretos — es la misma
 * URL que abriría cualquiera en un navegador. Se compara el `versionCode`, no el nombre: es lo
 * único que Android respeta para decidir si una actualización es más nueva.
 */
object Actualizador {

    private const val TAG = "YapeCaptor"
    // [MosGuard] Se lee la LISTA de releases (no /latest): cada edición publica con su propio prefijo
    // de tag (captor → "yape-v", guard → "mosguard-v"), así conviven sin robarse el auto-update.
    // /releases/latest devuelve UN solo release global — si el otro flavor publicara después, tapaba
    // al propio. Con la lista, cada uno busca el más nuevo de SU prefijo.
    private const val API_LISTA = "https://api.github.com/repos/Levo19/MOS/releases?per_page=30"

    data class Nueva(val versionCode: Int, val nombre: String, val url: String)

    /** ¿Hay una versión más nueva publicada PARA ESTA EDICIÓN? null si no, o si no se pudo averiguar. */
    fun buscar(ctx: Context): Nueva? {
        var con: HttpURLConnection? = null
        try {
            con = (URL(API_LISTA).openConnection() as HttpURLConnection).apply {
                connectTimeout = 12000; readTimeout = 15000
                setRequestProperty("Accept", "application/vnd.github+json")
                setRequestProperty("User-Agent", BuildConfig.APK_MATCH)
            }
            if (con.responseCode !in 200..299) return null
            val arr = JSONArray(con.inputStream.bufferedReader().use { it.readText() })
            val re = Regex(Regex.escape(BuildConfig.TAG_PREFIX) + "(\\d+)")
            var mejorCode = versionActual(ctx); var mejorUrl = ""; var mejorNom = ""
            for (i in 0 until arr.length()) {
                val rel = arr.getJSONObject(i)
                if (rel.optBoolean("draft") || rel.optBoolean("prerelease")) continue
                val code = re.find(rel.optString("tag_name"))?.groupValues?.get(1)?.toIntOrNull() ?: continue
                if (code <= mejorCode) continue
                val assets = rel.optJSONArray("assets") ?: continue
                for (k in 0 until assets.length()) {
                    val a = assets.getJSONObject(k)
                    val nom = a.optString("name")
                    // el APK de ESTA edición (YapeCaptor* o MosGuard*), no el del otro flavor
                    if (nom.endsWith(".apk") && nom.contains(BuildConfig.APK_MATCH)) {
                        mejorCode = code; mejorUrl = a.optString("browser_download_url"); mejorNom = rel.optString("name", rel.optString("tag_name")); break
                    }
                }
            }
            if (mejorUrl.isEmpty()) return null
            return Nueva(mejorCode, mejorNom, mejorUrl)
        } catch (e: Throwable) {
            Log.w(TAG, "no pude consultar la última versión: ${e.message}")
            return null
        } finally { try { con?.disconnect() } catch (_: Throwable) {} }
    }

    fun versionActual(ctx: Context): Int = try {
        val pi = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) pi.longVersionCode.toInt() else @Suppress("DEPRECATION") pi.versionCode
    } catch (_: Throwable) { 0 }

    fun nombreActual(ctx: Context): String = try {
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: ""
    } catch (_: Throwable) { "" }

    /** Baja el APK a la carpeta privada de la app. Devuelve el archivo o null. */
    fun descargar(ctx: Context, n: Nueva): File? {
        var con: HttpURLConnection? = null
        val destino = File(ctx.cacheDir, "yapecaptor-${n.versionCode}.apk")
        try {
            if (destino.exists()) destino.delete()
            con = (URL(n.url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 20000; readTimeout = 120000; instanceFollowRedirects = true   // 43MB en datos móviles: más tiempo
                setRequestProperty("User-Agent", "YapeCaptor")
            }
            if (con.responseCode !in 200..299) { Log.w(TAG, "descarga HTTP ${con.responseCode}"); return null }
            con.inputStream.use { ent -> destino.outputStream().use { sal -> ent.copyTo(sal) } }
            if (destino.length() < 1_000_000) { destino.delete(); return null }   // un APK sano pesa megas
            // ⚠ COMPLETITUD confiable: en vez de comparar Content-Length (el CDN de GitHub lo reporta raro tras
            // el redirect → rechazaba descargas buenas), validamos que el APK sea PARSEABLE/instalable. Si el
            // sistema no lo puede leer (vino trunco/corrupto) → dará "error de análisis del paquete" al instalar,
            // así que mejor borrarlo y reintentar. Si es parseable, es un APK íntegro.
            val ok = try { ctx.packageManager.getPackageArchiveInfo(destino.absolutePath, 0) != null } catch (_: Throwable) { false }
            if (!ok) { Log.w(TAG, "APK no parseable (trunco/corrupto)"); destino.delete(); return null }
            return destino
        } catch (e: Throwable) {
            Log.w(TAG, "fallo la descarga: ${e.message}"); try { destino.delete() } catch (_: Throwable) {}; return null
        } finally { try { con?.disconnect() } catch (_: Throwable) {} }
    }

    /** Abre el instalador de Android. Acá termina lo que la app puede hacer sola. */
    fun instalar(ctx: Context, apk: File): Boolean {
        return try {
            val uri: Uri = FileProvider.getUriForFile(ctx, ctx.packageName + ".fileprovider", apk)
            val i = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(i)
            true
        } catch (e: Throwable) {
            Log.e(TAG, "no pude abrir el instalador", e); false
        }
    }

    /**
     * Android 8+ exige un permiso aparte para que una app instale APKs. No es peligroso por sí
     * solo: el usuario igual confirma cada instalación en la pantalla del sistema.
     */
    fun puedeInstalar(ctx: Context): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) true
        else try { ctx.packageManager.canRequestPackageInstalls() } catch (_: Throwable) { false }

    fun pedirPermisoInstalar(ctx: Context) {
        try {
            ctx.startActivity(Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                .setData(Uri.parse("package:" + ctx.packageName))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Throwable) {}
    }
}
