package dev.levo.yapecaptor

import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * [MosGuard · fase 1] La ubicación del equipo, para el latido.
 *
 * LocationManager del sistema (NO Google Play Services): el APK no crece ni depende de Google y anda
 * en los equipos viejos de las zonas. Un anti-robo no necesita metros: necesita "está por acá".
 *
 * ⚠ Antes SOLO se leía `getLastKnownLocation` (posición cacheada). En un celular donde ninguna app usó
 * el GPS recientemente esa caché está VACÍA → con el permiso concedido igual mandaba lat/lon null
 * (el panel decía "permiso ✓" y parecía mentir). Ahora `obtener()` PIDE un fix ACTIVO (breve) y cae al
 * último conocido. Solo corre con BuildConfig.ES_GUARD.
 */
object Ubicacion {
    data class Fix(val lat: Double, val lon: Double, val precM: Float)

    private fun tienePermiso(ctx: Context): Boolean =
        ContextCompat.checkSelfPermission(ctx, "android.permission.ACCESS_FINE_LOCATION") == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(ctx, "android.permission.ACCESS_COARSE_LOCATION") == PackageManager.PERMISSION_GRANTED

    /** Último conocido de cualquier proveedor (barato, sin encender el GPS). Puede ser null. */
    fun ultima(ctx: Context): Fix? {
        try {
            if (!tienePermiso(ctx)) return null
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
            var mejor: Location? = null
            for (p in (try { lm.getProviders(true) } catch (_: Throwable) { emptyList<String>() })) {
                val l = try { lm.getLastKnownLocation(p) } catch (_: SecurityException) { null } catch (_: Throwable) { null } ?: continue
                if (mejor == null || l.time > mejor!!.time) mejor = l
            }
            val m = mejor ?: return null
            return Fix(m.latitude, m.longitude, if (m.hasAccuracy()) m.accuracy else -1f)
        } catch (_: Throwable) { return null }
    }

    /**
     * Ubicación para el latido: intenta un fix ACTIVO (hasta timeoutMs) y cae al último conocido.
     * Corre en el hilo del latido (background) → puede bloquear un ratito. Pide a red y GPS a la vez:
     * la red resuelve rápido en interiores, el GPS afina afuera; se toma el primero que llegue.
     */
    fun obtener(ctx: Context, timeoutMs: Long = 8000): Fix? {
        val cache = ultima(ctx)
        try {
            if (!tienePermiso(ctx)) return cache
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return cache
            val provs = (try { lm.getProviders(true) } catch (_: Throwable) { emptyList<String>() })
                .filter { it == LocationManager.GPS_PROVIDER || it == LocationManager.NETWORK_PROVIDER ||
                          (Build.VERSION.SDK_INT >= 31 && it == LocationManager.FUSED_PROVIDER) }
            if (provs.isEmpty()) return cache

            val latch = CountDownLatch(1)
            val holder = AtomicReference<Location?>(null)
            val looper = Looper.getMainLooper()

            if (Build.VERSION.SDK_INT >= 30) {
                val exec = ContextCompat.getMainExecutor(ctx)
                for (p in provs) {
                    try {
                        lm.getCurrentLocation(p, null, exec) { loc ->
                            if (loc != null && holder.compareAndSet(null, loc)) latch.countDown()
                        }
                    } catch (_: Throwable) {}
                }
            } else {
                val listener = object : LocationListener {
                    override fun onLocationChanged(loc: Location) { if (holder.compareAndSet(null, loc)) latch.countDown() }
                    override fun onProviderEnabled(p: String) {}
                    override fun onProviderDisabled(p: String) {}
                    override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
                }
                Handler(looper).post {
                    for (p in provs) { try { @Suppress("DEPRECATION") lm.requestSingleUpdate(p, listener, looper) } catch (_: Throwable) {} }
                }
            }

            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            val f = holder.get()
            return if (f != null) Fix(f.latitude, f.longitude, if (f.hasAccuracy()) f.accuracy else -1f) else cache
        } catch (_: Throwable) { return cache }
    }
}
