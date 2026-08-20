package dev.levo.yapecaptor

import android.content.Context
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * [MosGuard] El candado. La app SOLO se abre con la clave MASTER de 8 dígitos, y SIEMPRE se verifica
 * ONLINE contra el servidor — nunca se cachea, porque la clave puede cambiar (rotación). La acción
 * 'MOSGUARD_UNLOCK' exige nivel MASTER (nivel_minimo=3), así que un admin común NO entra: solo el dueño.
 *
 * Si no hay internet, no se puede verificar → no se abre. Es a propósito: sin poder confirmar contra
 * el servidor, un candado que se abre "por las dudas" no es un candado.
 */
object Desbloqueo {

    /** true solo si el servidor confirma que la clave es de un MASTER. Requiere internet. */
    fun verificar(ctx: Context, clave: String): Boolean {
        val c = clave.trim()
        if (c.length != 8 || !c.all { it.isDigit() }) return false
        var con: HttpURLConnection? = null
        try {
            con = (URL(Backend.URL.trimEnd('/') + "/rest/v1/rpc/verificar_clave_admin_p").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"; connectTimeout = 12000; readTimeout = 15000; doOutput = true
                setRequestProperty("apikey", Backend.ANON)
                setRequestProperty("Authorization", "Bearer " + Backend.ANON)
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Content-Profile", "mos")
            }
            val p = JSONObject().put("clave", c).put("accion", "MOSGUARD_UNLOCK").put("app", "mosGuard")
            con.outputStream.use { it.write(JSONObject().put("p", p).toString().toByteArray(Charsets.UTF_8)) }
            if (con.responseCode !in 200..299) return false
            val d = JSONObject(con.inputStream.bufferedReader().use { it.readText() })
            return d.optBoolean("ok", false) && d.optBoolean("autorizado", false)
        } catch (_: Throwable) {
            return false
        } finally { try { con?.disconnect() } catch (_: Throwable) {} }
    }
}
