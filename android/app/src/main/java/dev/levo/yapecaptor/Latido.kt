package dev.levo.yapecaptor

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * EL LATIDO — el equipo avisa que sigue vivo cada 15 minutos.
 *
 * Sin esto hay un agujero silencioso: si el celular se apaga, se queda sin datos o Android mata
 * la app, deja de capturar Yapes y NADIE se entera. Los tickets simplemente dejan de verificarse
 * y el admin lo descubre recién al cerrar caja, cuando ya no puede hacer nada.
 *
 * Un Yape capturado también cuenta como señal de vida, pero no alcanza: un día sin pagos por Yape
 * se vería igual que un celular muerto. Por eso el latido es aparte y no depende de que haya
 * movimiento.
 *
 * Se usa una alarma INEXACTA a propósito: Android la agrupa con otras y la deja pasar en las
 * ventanas de mantenimiento aunque el equipo esté en reposo profundo. Pedir exactitud gastaría
 * batería para nada — que llegue a los 10 o a los 18 minutos da igual.
 */
class LatidoReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "YapeCaptor"
        private const val CADA_MS = 10 * 60 * 1000L   // 10 min: alarma inexacta, no gasta bateria
        private const val ACCION = "dev.levo.yapecaptor.LATIDO"

        fun programar(ctx: Context) {
            try {
                val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                am.setInexactRepeating(
                    AlarmManager.RTC,
                    System.currentTimeMillis() + CADA_MS,
                    CADA_MS,
                    pi(ctx)
                )
                Log.i(TAG, "latido programado cada 10 min")
            } catch (e: Throwable) { Log.e(TAG, "no pude programar el latido", e) }
        }

        private fun pi(ctx: Context): PendingIntent {
            val i = Intent(ctx, LatidoReceiver::class.java).setAction(ACCION)
            val f = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
            return PendingIntent.getBroadcast(ctx, 7311, i, f)
        }

        /** Manda el latido. Silencioso: si no hay red, se pierde y el próximo lo cubre. */
        fun latir(ctx: Context) {
            val cfg = Prefs.leer(ctx)
            if (!cfg.completa()) return
            thread {
                var con: HttpURLConnection? = null
                try {
                    val url = URL(Backend.URL.trimEnd('/') + "/rest/v1/rpc/yape_latido")
                    con = (url.openConnection() as HttpURLConnection).apply {
                        requestMethod = "POST"; connectTimeout = 12000; readTimeout = 15000; doOutput = true
                        setRequestProperty("apikey", Backend.ANON)
                        setRequestProperty("Authorization", "Bearer " + Backend.ANON)
                        setRequestProperty("Content-Type", "application/json")
                        setRequestProperty("Content-Profile", "mos")
                    }
                    val p = JSONObject()
                        .put("secreto", cfg.secreto)
                        .put("equipo", Build.MODEL ?: "")
                        .put("pendientes", Cola.tamano(ctx))
                        .put("permiso", MainActivity.permisoNotificaciones(ctx))
                        .put("versionCode", Actualizador.versionActual(ctx))
                        .put("versionName", Actualizador.nombreActual(ctx))
                    // [MosGuard · fase 1] solo la edición guard adjunta la ubicación (última conocida).
                    // El YapeCaptor de producción no pide el permiso y esta rama no corre para él.
                    if (BuildConfig.ES_GUARD) {
                        val fix = try { Ubicacion.ultima(ctx) } catch (_: Throwable) { null }
                        if (fix != null) { p.put("lat", fix.lat).put("lon", fix.lon)
                            if (fix.precM >= 0) p.put("precM", fix.precM.toDouble()) }
                    }
                    con.outputStream.use { it.write(JSONObject().put("p", p).toString().toByteArray(Charsets.UTF_8)) }
                    // la respuesta trae el estado guard (NORMAL|ROBADO): se guarda para que MosGuard sepa
                    // si el dueño lo marcó robado (fase 2: subir ubicación seguido / foto). Hoy solo se recuerda.
                    if (con.responseCode in 200..299 && BuildConfig.ES_GUARD) {
                        try { val cuerpo = con.inputStream.bufferedReader().use { it.readText() }
                            val j = JSONObject(cuerpo)
                            Prefs.guardarGuardEstado(ctx, j.optString("guard", "NORMAL"))
                            Prefs.guardarCaptura(ctx, j.optBoolean("capturaYapes", true))
                            // [MosGuard fase 2] el servidor dice qué hacer con la cámara:
                            //  · foto=true      → una foto (one-shot)
                            //  · liveHasta>ahora → "en vivo" por cuadros hasta ese epoch (segundos)
                            if (j.optBoolean("foto", false)) CamaraGuard.foto(ctx)
                            val liveHasta = j.optLong("liveHasta", 0L)
                            if (liveHasta > 0 && liveHasta * 1000L > System.currentTimeMillis()) CamaraGuard.vivo(ctx, liveHasta * 1000L)
                        } catch (_: Throwable) {}
                    } else { con.responseCode }
                } catch (_: Throwable) {
                } finally { try { con?.disconnect() } catch (_: Throwable) {} }
            }
        }
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        val ctx = context ?: return
        // vigilante: si el listener se desconectó y Android no lo volvió a atar, se le insiste
        if (!Prefs.listenerVivo(ctx)) YapeListener.reatar(ctx)
        GuardiaService.arrancar(ctx)   // si Android lo mató, vuelve con el latido
        latir(ctx)
        // aprovechamos el despertar para vaciar lo que haya quedado en cola sin red
        if (Cola.tamano(ctx) > 0) ColaService.despertar(ctx)
    }
}
