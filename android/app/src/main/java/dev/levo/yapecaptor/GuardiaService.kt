package dev.levo.yapecaptor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * EL GUARDIA — mantiene el equipo "caliente" para que Yape no deje de notificar.
 *
 * Lo que el dueño ve: "Yape a veces notifica y a veces no; cuando los pagos son seguidos
 * notifica, cuando pasa un rato se enfría". Eso NO es Yape: es el celular durmiéndose.
 * Con la pantalla apagada, Android baja la radio Wi-Fi a modo ahorro, el socket de Google
 * (por donde llegan los push de Yape) se queda mudo y recién se da cuenta en el próximo
 * latido de Google (15-28 min). Por eso el Yape "demora" justo después de una pausa.
 *
 * Este servicio, mientras la app esté exenta de optimización de batería:
 *   · mantiene la CPU despierta (wakelock parcial) y la Wi-Fi en alto rendimiento (WifiLock),
 *     que es lo que impide que la radio se duerma entre Yapes;
 *   · cada 2,5 min hace un pedido mínimo a la red (mantiene la conexión viva) y, si el
 *     lector de notificaciones se soltó, se lo re-ata;
 *   · se arranca al abrir la app, al prender el celular y cuando el listener conecta.
 *
 * Consume batería, sí: está pensado para un celular de mostrador, enchufado.
 */
class GuardiaService : Service() {

    companion object {
        private const val TAG = "YapeCaptor"
        private const val CANAL = "yape_captor"
        private const val NOTIF_ID = 4712
        private const val CADA_MS = 150_000L          // 2,5 min
        @Volatile private var corriendo = false

        fun arrancar(ctx: Context) {
            try {
                if (!Prefs.leer(ctx).completa()) return     // sin emparejar no hay nada que cuidar
                val i = Intent(ctx, GuardiaService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
                else ctx.startService(i)
            } catch (e: Throwable) { Log.e(TAG, "no pude arrancar el guardia", e) }
        }
    }

    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        enPrimerPlano()
        tomarLocks()
        if (!corriendo) {
            corriendo = true
            thread(name = "yape-guardia", isDaemon = true) {
                try { rondar() } finally { corriendo = false }
            }
        }
        return START_STICKY
    }

    private fun enPrimerPlano() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val canal = NotificationChannel(CANAL, "Captura de Yapes", NotificationManager.IMPORTANCE_MIN)
            canal.description = "Mantiene viva la captura de notificaciones de Yape"
            nm.createNotificationChannel(canal)
        }
        val n = Notification.Builder(this, CANAL)
            .setContentTitle("Captura de Yapes activa")
            .setContentText("Manteniendo el equipo despierto para que Yape notifique al instante")
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setOngoing(true)
            .build()
        try { startForeground(NOTIF_ID, n) } catch (e: Throwable) { Log.e(TAG, "startForeground guardia", e) }
    }

    private fun tomarLocks() {
        try {
            if (wake == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "YapeCaptor:guardia").apply { setReferenceCounted(false) }
            }
            if (wake?.isHeld != true) wake?.acquire()
        } catch (e: Throwable) { Log.w(TAG, "wakelock: ${e.message}") }
        try {
            if (wifi == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val modo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) WifiManager.WIFI_MODE_FULL_HIGH_PERF else 3 /* FULL_HIGH_PERF */
                wifi = wm.createWifiLock(modo, "YapeCaptor:guardia").apply { setReferenceCounted(false) }
            }
            if (wifi?.isHeld != true) wifi?.acquire()
        } catch (e: Throwable) { Log.w(TAG, "wifilock: ${e.message}") }
    }

    private fun soltarLocks() {
        try { if (wake?.isHeld == true) wake?.release() } catch (_: Throwable) {}
        try { if (wifi?.isHeld == true) wifi?.release() } catch (_: Throwable) {}
    }

    /** La ronda: red viva + listener atado, cada 2,5 min, mientras el equipo esté emparejado. */
    private fun rondar() {
        var vueltas = 0
        while (true) {
            if (!Prefs.leer(this).completa()) break
            pingRed()
            YapeListener.reatar(this)
            if (Cola.tamano(this) > 0) ColaService.despertar(this)
            vueltas++
            if (vueltas % 4 == 0) LatidoReceiver.latir(this)     // cada 10 min, además de la alarma
            try { Thread.sleep(CADA_MS) } catch (_: InterruptedException) { break }
        }
        soltarLocks()
        try { stopForeground(true) } catch (_: Throwable) {}
        stopSelf()
    }

    /** Un pedido mínimo: mantiene la conexión de datos viva. Si falla, no pasa nada. */
    private fun pingRed() {
        var con: HttpURLConnection? = null
        try {
            con = (URL(Backend.URL.trimEnd('/') + "/auth/v1/health").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"; connectTimeout = 8000; readTimeout = 8000
                setRequestProperty("apikey", Backend.ANON)
            }
            con.responseCode
        } catch (_: Throwable) {
        } finally { try { con?.disconnect() } catch (_: Throwable) {} }
    }

    override fun onDestroy() { soltarLocks(); super.onDestroy() }
}
