package dev.levo.yapecaptor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.concurrent.thread

/**
 * Entrega la cola al servidor y reintenta hasta lograrlo.
 *
 * Corre en primer plano (con su notificación fija) porque Android mata sin aviso los servicios
 * de fondo cuando la pantalla está apagada — y este equipo va a estar todo el día en un mostrador
 * con la pantalla apagada. La notificación fija es el precio de que no lo maten.
 */
class ColaService : Service() {

    companion object {
        private const val TAG = "YapeCaptor"
        private const val CANAL = "yape_captor"
        private const val NOTIF_ID = 4711
        @Volatile private var trabajando = false

        fun despertar(ctx: Context) {
            try {
                val i = Intent(ctx, ColaService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
                else ctx.startService(i)
            } catch (e: Throwable) { Log.e(TAG, "no pude despertar el servicio", e) }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        arrancarEnPrimerPlano()
        if (!trabajando) {
            trabajando = true
            thread(name = "yape-cola") {
                try { vaciarCola() } finally { trabajando = false; detenerSiVacio() }
            }
        }
        return START_STICKY
    }

    private fun arrancarEnPrimerPlano() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val canal = NotificationChannel(CANAL, "Captura de Yapes", NotificationManager.IMPORTANCE_MIN)
            canal.description = "Mantiene viva la captura de notificaciones de Yape"
            nm.createNotificationChannel(canal)
        }
        val pend = Cola.tamano(this)
        val n = Notification.Builder(this, CANAL)
            .setContentTitle("Captura de Yapes activa")
            .setContentText(if (pend > 0) "$pend por entregar" else "Todo entregado")
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setOngoing(true)
            .build()
        try { startForeground(NOTIF_ID, n) } catch (e: Throwable) { Log.e(TAG, "startForeground", e) }
    }

    private fun detenerSiVacio() {
        if (Cola.tamano(this) == 0) {
            try { stopForeground(true) } catch (_: Throwable) {}
            stopSelf()
        }
    }

    private fun vaciarCola() {
        val cfg = Prefs.leer(this)
        if (!cfg.completa()) { Log.w(TAG, "sin configurar: la cola espera"); return }

        var intentosRonda = 0
        while (true) {
            val pend = Cola.pendientes(this)
            if (pend.isEmpty()) break
            var alguna = false
            for (c in pend) {
                // techo de reintentos por captura: si el servidor la rechaza SIEMPRE (texto
                // ilegible, dispositivo revocado), no puede bloquear a las demás para siempre.
                if (c.intentos >= 25) { Log.w(TAG, "abandono tras 25 intentos: ${c.notifKey}"); Cola.quitar(this, c.notifKey); continue }
                val r = entregar(cfg, c)
                if (r) { Cola.quitar(this, c.notifKey); alguna = true; Prefs.marcarEntrega(this) }
                else { Cola.marcarIntento(this, c.notifKey) }
            }
            if (!alguna) {
                intentosRonda++
                if (intentosRonda >= 6) break            // sin red: se reintenta al próximo evento
                try { Thread.sleep(4000L * intentosRonda) } catch (_: InterruptedException) { break }
            } else intentosRonda = 0
        }
        arrancarEnPrimerPlano()   // refrescar el contador de la notificación fija
    }

    /** Un POST a la RPC de Supabase. true = el servidor lo dio por guardado. */
    private fun entregar(cfg: Config, c: Captura): Boolean {
        var con: HttpURLConnection? = null
        return try {
            val url = URL(cfg.supabaseUrl.trimEnd('/') + "/rest/v1/rpc/yape_ingesta")
            con = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15000
                readTimeout = 20000
                doOutput = true
                setRequestProperty("apikey", cfg.anonKey)
                setRequestProperty("Authorization", "Bearer " + cfg.anonKey)
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Content-Profile", "mos")
            }
            val p = JSONObject().apply {
                put("secreto", cfg.secreto)
                put("notifKey", c.notifKey)
                put("texto", c.texto)
                put("titulo", c.titulo)
                put("paquete", c.paquete)
                put("ts", iso(c.tsMillis))
            }
            con.outputStream.use { it.write(JSONObject().put("p", p).toString().toByteArray(Charsets.UTF_8)) }

            val code = con.responseCode
            val cuerpo = (if (code in 200..299) con.inputStream else con.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (code !in 200..299) { Log.w(TAG, "HTTP $code: $cuerpo"); return false }

            val ok = try { JSONObject(cuerpo).optBoolean("ok", false) } catch (_: Throwable) { false }
            if (!ok) {
                val err = try { JSONObject(cuerpo).optString("error") } catch (_: Throwable) { "" }
                Log.w(TAG, "servidor rechazó: $err")
                Prefs.guardarUltimoError(this, err.ifBlank { "rechazado" })
                // dispositivo revocado desde MOS: este equipo ya no entrega. Se vacía la cola
                // (esos Yapes no van a ningún lado) y la pantalla lo dice. Antes reintentaba 25
                // veces cada captura contra una puerta cerrada.
                if (err.contains("NO_AUTORIZADO")) {
                    Cola.pendientes(this).forEach { Cola.quitar(this, it.notifKey) }
                    Prefs.guardarUltimoError(this, "Equipo revocado desde MOS — pedí un código nuevo")
                }
                return false
            }
            Prefs.guardarUltimoError(this, "")
            true
        } catch (e: Throwable) {
            Log.w(TAG, "fallo de red: ${e.message}")
            false
        } finally {
            try { con?.disconnect() } catch (_: Throwable) {}
        }
    }

    private fun iso(ms: Long): String {
        val f = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        f.timeZone = TimeZone.getTimeZone("UTC")
        return f.format(Date(ms))
    }
}
