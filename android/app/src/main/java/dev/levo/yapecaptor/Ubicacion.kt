package dev.levo.yapecaptor

import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * [MosGuard · fase 1] La ubicación del equipo, para el latido.
 *
 * Se usa el LocationManager del sistema (no Google Play Services): así el APK no crece ni depende
 * de servicios de Google, y funciona en los equipos viejos de las zonas. Se lee la ÚLTIMA posición
 * conocida de cualquier proveedor (GPS, red, fused) — barato, sin encender el GPS ni gastar batería.
 * Un anti-robo no necesita precisión de metros: necesita "está por acá".
 *
 * Solo se invoca cuando BuildConfig.ES_GUARD es true; el YapeCaptor de producción nunca la toca.
 */
object Ubicacion {
    data class Fix(val lat: Double, val lon: Double, val precM: Float)

    fun ultima(ctx: Context): Fix? {
        try {
            val fino = ContextCompat.checkSelfPermission(ctx, "android.permission.ACCESS_FINE_LOCATION") == PackageManager.PERMISSION_GRANTED
            val grueso = ContextCompat.checkSelfPermission(ctx, "android.permission.ACCESS_COARSE_LOCATION") == PackageManager.PERMISSION_GRANTED
            if (!fino && !grueso) return null
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
            var mejor: Location? = null
            val provs = try { lm.getProviders(true) } catch (_: Throwable) { emptyList<String>() }
            for (p in provs) {
                val l = try { lm.getLastKnownLocation(p) } catch (_: SecurityException) { null } catch (_: Throwable) { null } ?: continue
                if (mejor == null || l.time > mejor!!.time) mejor = l
            }
            val m = mejor ?: return null
            return Fix(m.latitude, m.longitude, if (m.hasAccuracy()) m.accuracy else -1f)
        } catch (_: Throwable) { return null }
    }
}
