package dev.levo.yapecaptor

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.telephony.TelephonyManager

/**
 * [MosGuard nativo] Telemetría del equipo para el latido: batería, carga, red, señal y SIM.
 * Nada de esto lo puede dar una web. Todo best-effort (si algo no está disponible, va null y el
 * latido no lo pisa).
 *
 * SIM: en Android 10+ el ICCID/serial real está BLOQUEADO para apps normales. Usamos el operador
 * (MCC/MNC + nombre) como huella: detecta el caso típico de robo = le meten un chip de OTRA compañía.
 * Un cambio de chip de la MISMA compañía no se distingue (límite del sistema, no del código).
 */
object Telemetria {
    data class Datos(
        val bateria: Int?, val cargando: Boolean?, val red: String?, val senal: Int?,
        val simSerial: String?, val simOperador: String?, val simNumero: String?
    )

    fun leer(ctx: Context): Datos {
        return Datos(
            bateria = bateria(ctx), cargando = cargando(ctx), red = red(ctx), senal = senal(ctx),
            simSerial = simMccMnc(ctx), simOperador = simOperador(ctx), simNumero = simNumero(ctx)
        )
    }

    private fun bateriaIntent(ctx: Context): Intent? =
        try { ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) } catch (_: Throwable) { null }

    private fun bateria(ctx: Context): Int? {
        val bi = bateriaIntent(ctx) ?: return null
        val level = bi.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = bi.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        return if (level >= 0 && scale > 0) (level * 100 / scale) else null
    }

    private fun cargando(ctx: Context): Boolean? {
        val bi = bateriaIntent(ctx) ?: return null
        val st = bi.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return if (st < 0) null else (st == BatteryManager.BATTERY_STATUS_CHARGING || st == BatteryManager.BATTERY_STATUS_FULL)
    }

    private fun red(ctx: Context): String? {
        return try {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
            val nc = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "sin"
            when {
                nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "movil"
                else -> "otro"
            }
        } catch (_: Throwable) { null }
    }

    /** 0-4, best-effort. WiFi por rssi; celular por SignalStrength.level. */
    private fun senal(ctx: Context): Int? {
        try {
            val r = red(ctx)
            if (r == "wifi") {
                val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
                @Suppress("DEPRECATION") val rssi = wm.connectionInfo?.rssi ?: return null
                return try {
                    if (Build.VERSION.SDK_INT >= 30) wm.calculateSignalLevel(rssi).coerceIn(0, 4)
                    else @Suppress("DEPRECATION") WifiManager.calculateSignalLevel(rssi, 5).coerceIn(0, 4)
                } catch (_: Throwable) { null }
            }
            if (r == "movil" && Build.VERSION.SDK_INT >= 28) {
                val tm = ctx.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return null
                return try { tm.signalStrength?.level?.coerceIn(0, 4) } catch (_: Throwable) { null }
            }
        } catch (_: Throwable) {}
        return null
    }

    private fun tm(ctx: Context) = ctx.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager

    /** MCC+MNC del operador de SIM ("" si no hay chip) — huella permitida sin permisos. */
    private fun simMccMnc(ctx: Context): String? =
        try { tm(ctx)?.simOperator?.takeIf { it.isNotBlank() } } catch (_: Throwable) { null }

    private fun simOperador(ctx: Context): String? =
        try { tm(ctx)?.simOperatorName?.takeIf { it.isNotBlank() } } catch (_: Throwable) { null }

    /** Número de línea: casi siempre null en Android 10+ (necesita permiso/privilegio); best-effort. */
    private fun simNumero(ctx: Context): String? =
        try {
            if (ctx.checkSelfPermission(android.Manifest.permission.READ_PHONE_STATE) == android.content.pm.PackageManager.PERMISSION_GRANTED)
                @Suppress("DEPRECATION", "HardwareIds") tm(ctx)?.line1Number?.takeIf { it.isNotBlank() }
            else null
        } catch (_: Throwable) { null }
}
