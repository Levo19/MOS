package dev.levo.yapecaptor

import android.content.Context

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * El corazón de la app: Android le entrega TODA notificación que se muestre en el equipo,
 * y este servicio se queda solo con las de Yape.
 *
 * Dos decisiones que importan:
 *
 * 1. NO se parsea acá. El texto crudo viaja entero al servidor y el monto y el nombre se
 *    extraen allá. Motivo: Yape cambia el formato de sus mensajes cada tanto, y arreglar un
 *    patrón en el servidor es inmediato — arreglarlo en el APK obliga a recompilar, reinstalar
 *    y perseguir el celular. La app manda; el servidor entiende.
 *
 * 2. Nada se pierde por falta de señal. Cada notificación se encola en disco y se reintenta
 *    hasta que el servidor confirma. El `notifKey` la hace idempotente: si se entrega dos
 *    veces, el servidor guarda una sola.
 */
class YapeListener : NotificationListenerService() {

    companion object {
        private const val TAG = "YapeCaptor"

        /**
         * Paquetes de Yape. Se incluyen las variantes conocidas porque el nombre cambió entre
         * versiones y hay equipos con la app vieja instalada.
         */
        val PAQUETES_YAPE = setOf(
            "com.bcp.innovacxion.yapeapp",
            "com.bcp.yape",
            "pe.com.bcp.yape"
        )

        /**
         * Filtro de contenido: solo interesan los COBROS. Yape también notifica promociones,
         * "tu yapeo fue enviado" (dinero que SALE) y avisos varios. Dejar pasar un envío
         * saliente contaminaría la caja con plata que no entró.
         */
        private val ENTRANTE = Regex(
            "(te (envió|envio|ha yapeado|yapeó|yapeo))|(recibiste)|(pago recibido)|(te pagó|te pago)",
            RegexOption.IGNORE_CASE
        )
        private val SALIENTE = Regex(
            "(yapeaste a)|(enviaste)|(tu yapeo fue)|(pago enviado)|(le yapeaste)",
            RegexOption.IGNORE_CASE
        )
        private val MONTO = Regex("S/\\.?\\s*[0-9]")

        /** Pide a Android que vuelva a atar el listener (si el permiso está dado). Idempotente. */
        fun reatar(ctx: Context) {
            try {
                if (!MainActivity.permisoNotificaciones(ctx)) return
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N)
                    android.service.notification.NotificationListenerService.requestRebind(android.content.ComponentName(ctx, YapeListener::class.java))
            } catch (_: Throwable) {}
        }

        /** ¿Este texto es un cobro que entró? */
        fun esCobroEntrante(texto: String): Boolean {
            if (texto.isBlank()) return false
            if (SALIENTE.containsMatchIn(texto)) return false      // dinero que SALE: no es nuestro
            if (!MONTO.containsMatchIn(texto)) return false        // sin monto no sirve de nada
            return ENTRANTE.containsMatchIn(texto)
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        procesar(sbn)
    }

    /**
     * Procesa UNA notificación, venga en vivo (onNotificationPosted) o del barrido de reconexión
     * (onListenerConnected). Idempotente: el server deduplica por notifKey, así que re-pasar una
     * notificación ya capturada es inofensivo (nunca duplica ni re-abre un Yape matcheado).
     */
    private fun procesar(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        try {
            if (n.packageName !in PAQUETES_YAPE) return
            // [883] MosGuard: si el dueño apagó la captura de este equipo (celular personal, solo
            // resguardo), no se lee ni se guarda la notificación de Yape. Es privacidad, no un bug.
            if (!Prefs.captura(applicationContext)) return

            val extras = n.notification?.extras ?: return
            val titulo = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
            val cuerpo = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
            val grande = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString().orEmpty()
            // el texto largo, cuando existe, trae el nombre completo del pagador
            val texto = listOf(titulo, grande.ifBlank { cuerpo })
                .filter { it.isNotBlank() }
                .joinToString(" ")
                .trim()

            if (!esCobroEntrante(texto)) {
                Log.d(TAG, "descartada (no es cobro entrante): $texto")
                return
            }

            // Clave estable de la notificación. Android reenvía la MISMA notificación cuando la
            // app la actualiza; sin esta clave el mismo Yape entraría varias veces y el cierre
            // de caja mostraría plata que no existe.
            val key = "${n.packageName}|${n.key ?: n.id}|${n.postTime}"

            Cola.encolar(
                applicationContext,
                Captura(
                    notifKey = key,
                    texto = texto,
                    titulo = titulo,
                    paquete = n.packageName,
                    // La hora del Yape: si el celular estuvo sin datos, al volver la señal le caen
                    // TODAS las notificaciones juntas con postTime = ahora, y el Yape de las 9:35
                    // queda fechado 10:07 → no calza con su ticket. Yape pone la hora real del
                    // evento en `when`; si viene y es anterior al postTime (hasta 3 días), se usa.
                    tsMillis = run {
                        val post = if (n.postTime > 0) n.postTime else System.currentTimeMillis()
                        val cuando = n.notification?.`when` ?: 0L
                        if (cuando > 0 && cuando < post && post - cuando < 3L * 86400000L) cuando else post
                    }
                )
            )
            ColaService.despertar(applicationContext)
            // un Yape capturado es la mejor prueba de vida: el estado en MOS se refresca ya,
            // sin esperar al próximo latido de 10 min
            LatidoReceiver.latir(applicationContext)
        } catch (e: Throwable) {
            // Nunca lanzar acá: una excepción en el listener puede hacer que Android
            // desconecte el servicio y el equipo deje de capturar sin que nadie se entere.
            Log.e(TAG, "error procesando notificación", e)
        }
    }

    override fun onListenerConnected() {
        Log.i(TAG, "listener conectado")
        Prefs.marcarListenerVivo(applicationContext, true)
        GuardiaService.arrancar(applicationContext)
        ColaService.despertar(applicationContext)
        LatidoReceiver.programar(applicationContext)   // el equipo empieza a avisar que está vivo
        LatidoReceiver.latir(applicationContext)
        // [FIX Redmi/MIUI] Barrido de reconexión. MIUI mata y re-ata el listener SIN matar la app (la
        //   guardia/latido siguen vivos → el equipo se ve "en línea"), pero un Yape que llegó mientras el
        //   listener estuvo desconectado quedó VISIBLE en la barra y onNotificationPosted NUNCA disparó → se
        //   perdía para siempre. Aquí, al reconectar, releemos lo que YA está en la barra y lo pasamos por el
        //   mismo camino. Idempotente (el server deduplica por notifKey) → jamás duplica ni re-abre un Yape ya
        //   matcheado, y recupera el correcto con su hora real (`when`). La guardia pide rebind cada ~2,5 min,
        //   así que este barrido rescata el Yape mientras su notificación siga mostrándose. (Moto/near-stock no
        //   lo necesita porque su listener nunca se desata, pero el barrido no le hace daño.)
        try { activeNotifications?.forEach { procesar(it) } } catch (e: Throwable) { Log.w(TAG, "barrido de reconexión falló", e) }
    }

    override fun onListenerDisconnected() {
        Log.w(TAG, "listener DESCONECTADO")
        Prefs.marcarListenerVivo(applicationContext, false)
        // pedirle a Android que lo vuelva a atar (pasa tras actualizar la app o al reiniciar)
        try { requestRebind(android.content.ComponentName(this, YapeListener::class.java)) } catch (_: Throwable) {}
    }
}
