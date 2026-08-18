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

/**
 * La única pantalla. Se usa una vez, al instalar: pegar los tres datos, dar el permiso, y listo.
 * De ahí en más el equipo trabaja solo y esta pantalla sirve para UNA cosa: mirar si está
 * capturando de verdad. Por eso el semáforo de arriba es lo más grande de la pantalla.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var tvEstado: TextView
    private lateinit var tvDetalle: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvEstado = findViewById(R.id.tvEstado)
        tvDetalle = findViewById(R.id.tvDetalle)

        val etUrl = findViewById<EditText>(R.id.etUrl)
        val etAnon = findViewById<EditText>(R.id.etAnon)
        val etSec = findViewById<EditText>(R.id.etSecreto)

        val c = Prefs.leer(this)
        etUrl.setText(c.supabaseUrl)
        etAnon.setText(c.anonKey)
        etSec.setText(c.secreto)

        findViewById<Button>(R.id.btnGuardar).setOnClickListener {
            Prefs.guardar(this, Config(etUrl.text.toString(), etAnon.text.toString(), etSec.text.toString()))
            Toast.makeText(this, "Guardado", Toast.LENGTH_SHORT).show()
            ColaService.despertar(this)
            pintar()
        }

        // Android NO deja conceder este permiso por código: tiene que entrar el dueño del
        // equipo a Ajustes y darlo a mano. Este botón solo lleva a la pantalla correcta.
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
            !perm         -> "⛔ Falta el permiso" to 0xFFEF4444.toInt()
            !cfg.completa() -> "⚙ Falta configurar" to 0xFFF59E0B.toInt()
            err.isNotBlank() -> "⚠ El servidor rechaza" to 0xFFF59E0B.toInt()
            else          -> "✅ Capturando" to 0xFF10B981.toInt()
        }
        tvEstado.text = txt
        tvEstado.setTextColor(color)

        val ult = Prefs.ultimaEntrega(this)
        val cuando = if (ult == 0L) "todavía ninguna"
                     else DateUtils.getRelativeTimeSpanString(ult, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
        tvDetalle.text = buildString {
            appendLine("Permiso de notificaciones: " + if (perm) "concedido" else "NO concedido")
            appendLine("Servicio atado: " + if (Prefs.listenerVivo(this@MainActivity)) "sí" else "no (se re-ata solo)")
            appendLine("Yapes entregados: " + Prefs.total(this@MainActivity))
            appendLine("Última entrega: $cuando")
            appendLine("En cola por entregar: $pend")
            if (err.isNotBlank()) appendLine("Último rechazo: $err")
        }.trim()
    }

    /**
     * Prueba de punta a punta SIN esperar un Yape real: manda una captura marcada como prueba.
     * El servidor la guarda con su texto crudo; si el monto sale bien, toda la cadena funciona.
     */
    private fun probar() {
        val cfg = Prefs.leer(this)
        if (!cfg.completa()) { Toast.makeText(this, "Configurá primero los 3 datos", Toast.LENGTH_LONG).show(); return }
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
