package dev.levo.yapecaptor

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.text.format.DateUtils
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * La única pantalla. Se usa una vez, al instalar: seis letras y el permiso. Nada más.
 *
 * El emparejamiento por código evita lo que el dueño quería evitar — tipear tres cadenas
 * larguísimas en un celular. La URL y la clave anon vienen compiladas (no son secretos), y el
 * secreto propio del equipo lo entrega el servidor a cambio del código, una sola vez.
 *
 * De ahí en más el equipo trabaja solo y esta pantalla sirve para UNA cosa: ver si está
 * capturando de verdad. Por eso el semáforo es lo más grande.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var tvEstado: TextView
    private lateinit var tvDetalle: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvEstado = findViewById(R.id.tvEstado)
        tvDetalle = findViewById(R.id.tvDetalle)

        findViewById<Button>(R.id.btnEmparejar).setOnClickListener {
            val cod = findViewById<EditText>(R.id.etCodigo).text.toString()
                .uppercase().replace(Regex("[^A-Z0-9]"), "")
            if (cod.length != 6) { Toast.makeText(this, "El código son 6 letras", Toast.LENGTH_LONG).show(); return@setOnClickListener }
            emparejar(cod)
        }

        // Android NO deja conceder este permiso por código: tiene que entrar una persona a
        // Ajustes y darlo a mano. Este botón solo lleva a la pantalla correcta.
        findViewById<Button>(R.id.btnPermiso).setOnClickListener {
            try { startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")) }
            catch (_: Throwable) { startActivity(Intent(Settings.ACTION_SETTINGS)) }
        }

        findViewById<Button>(R.id.btnProbar).setOnClickListener { probar() }
    }

    override fun onResume() { super.onResume(); pintar() }

    private fun permisoConcedido(): Boolean =
        Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
            ?.contains(packageName) == true

    private fun pintar() {
        val cfg = Prefs.leer(this)
        val perm = permisoConcedido()
        val pend = Cola.tamano(this)
        val err = Prefs.ultimoError(this)

        val (txt, color) = when {
            !cfg.completa() -> "⚙ Falta emparejar" to 0xFFF59E0B.toInt()
            !perm           -> "⛔ Falta el permiso" to 0xFFEF4444.toInt()
            err.isNotBlank() -> "⚠ El servidor rechaza" to 0xFFF59E0B.toInt()
            else            -> "✅ Capturando" to 0xFF10B981.toInt()
        }
        tvEstado.text = txt
        tvEstado.setTextColor(color)

        val ult = Prefs.ultimaEntrega(this)
        val cuando = if (ult == 0L) "todavía ninguna"
                     else DateUtils.getRelativeTimeSpanString(ult, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
        tvDetalle.text = buildString {
            if (cfg.completa()) {
                appendLine("Equipo: " + cfg.nombre.ifBlank { "(sin nombre)" })
                appendLine("Zona: " + cfg.zona.ifBlank { "todas" })
            } else appendLine("Sin emparejar — pedí el código en MOS → Config")
            appendLine("Permiso de notificaciones: " + if (perm) "concedido" else "NO concedido")
            appendLine("Yapes entregados: " + Prefs.total(this@MainActivity))
            appendLine("Última entrega: $cuando")
            appendLine("En cola por entregar: $pend")
            if (err.isNotBlank()) appendLine("Último rechazo: $err")
        }.trim()
    }

    /** Canjea el código por el secreto de este equipo. El código se quema al usarse. */
    private fun emparejar(codigo: String) {
        Toast.makeText(this, "Emparejando…", Toast.LENGTH_SHORT).show()
        thread {
            var con: HttpURLConnection? = null
            var msg: String
            try {
                val url = URL(Backend.URL.trimEnd('/') + "/rest/v1/rpc/yape_emparejar")
                con = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"; connectTimeout = 15000; readTimeout = 20000; doOutput = true
                    setRequestProperty("apikey", Backend.ANON)
                    setRequestProperty("Authorization", "Bearer " + Backend.ANON)
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Content-Profile", "mos")
                }
                val p = JSONObject().put("codigo", codigo).put("equipo", android.os.Build.MODEL ?: "")
                con.outputStream.use { it.write(JSONObject().put("p", p).toString().toByteArray(Charsets.UTF_8)) }
                val code = con.responseCode
                val cuerpo = (if (code in 200..299) con.inputStream else con.errorStream)
                    ?.bufferedReader()?.use { it.readText() }.orEmpty()
                val j = JSONObject(cuerpo)
                if (j.optBoolean("ok", false)) {
                    val d = j.getJSONObject("data")
                    Prefs.guardar(this, Config(d.optString("secreto"), d.optString("nombre"), d.optString("zona")))
                    Prefs.guardarUltimoError(this, "")
                    msg = "✅ Emparejado: " + d.optString("nombre")
                    ColaService.despertar(this)
                } else {
                    msg = "❌ " + j.optString("error", "no se pudo emparejar")
                }
            } catch (e: Throwable) {
                msg = "❌ Sin conexión: " + (e.message ?: "")
            } finally { try { con?.disconnect() } catch (_: Throwable) {} }

            runOnUiThread {
                Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
                findViewById<EditText>(R.id.etCodigo).setText("")
                pintar()
            }
        }
    }

    /**
     * Prueba de punta a punta SIN esperar un Yape real: manda una captura marcada como prueba.
     * Si aparece en MOS con su monto, toda la cadena funciona.
     */
    private fun probar() {
        if (!Prefs.leer(this).completa()) { Toast.makeText(this, "Emparejá primero", Toast.LENGTH_LONG).show(); return }
        Cola.encolar(this, Captura(
            notifKey = "PRUEBA|" + System.currentTimeMillis(),
            texto = "PRUEBA YapeCaptor: Recibiste un pago de S/ 0.01 de PRUEBA DEL EQUIPO",
            titulo = "Prueba",
            paquete = "dev.levo.yapecaptor",
            tsMillis = System.currentTimeMillis()
        ))
        ColaService.despertar(this)
        Toast.makeText(this, "Prueba enviada — miralo en MOS", Toast.LENGTH_LONG).show()
    }
}
