package dev.levo.yapecaptor

import android.content.Context
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.PowerManager
import android.util.Log
import kotlin.concurrent.thread

/**
 * [MosGuard nativo] ALARMA remota: sonido fuerte (aunque el celular esté en silencio) + linterna
 * parpadeando, para ubicar el equipo o asustar al ladrón. La web NO puede subir el volumen ni prender
 * el flash — esto es puro nativo.
 *
 * No es un foreground service (evita el bloqueo de arrancar FGS de fondo): corre en un hilo dentro del
 * proceso que GuardiaService ya mantiene vivo, con un wakelock, por `seg` segundos.
 */
object AlarmaGuard {
    private const val TAG = "MosGuardAlarma"
    @Volatile private var sonando = false
    @Volatile private var finMs = 0L

    /** Suena+parpadea por `seg` segundos. Si ya está sonando, extiende el fin. seg<=0 la corta. */
    fun sonar(ctx: Context, seg: Int) {
        if (seg <= 0) { finMs = 0L; return }
        finMs = System.currentTimeMillis() + seg.coerceAtMost(300) * 1000L
        if (sonando) return
        sonando = true
        thread(name = "guard-alarma", isDaemon = true) {
            val app = ctx.applicationContext
            var wl: PowerManager.WakeLock? = null
            var mp: MediaPlayer? = null
            var volPrev = -1
            var am: AudioManager? = null
            try {
                wl = (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "mosguard:alarma").apply { acquire(310_000L) }
                // volumen de ALARMA al máximo (se restaura al final)
                am = app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                if (am != null) {
                    volPrev = am.getStreamVolume(AudioManager.STREAM_ALARM)
                    am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
                }
                // sonido de alarma en loop
                try {
                    val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    mp = MediaPlayer().apply {
                        setAudioAttributes(AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                        setDataSource(app, uri); isLooping = true; prepare(); start()
                    }
                } catch (e: Throwable) { Log.w(TAG, "audio: ${e.message}") }

                // linterna parpadeando
                val cm = app.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
                val flashId = try { cm?.cameraIdList?.firstOrNull { id ->
                    cm.getCameraCharacteristics(id).get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                } } catch (_: Throwable) { null }
                var on = false
                while (System.currentTimeMillis() < finMs) {
                    if (flashId != null) { on = !on; try { cm?.setTorchMode(flashId, on) } catch (_: Throwable) {} }
                    try { Thread.sleep(450) } catch (_: InterruptedException) { break }
                }
                if (flashId != null) try { cm?.setTorchMode(flashId, false) } catch (_: Throwable) {}
            } catch (e: Throwable) { Log.e(TAG, "alarma", e) } finally {
                try { mp?.stop(); mp?.release() } catch (_: Throwable) {}
                try { if (am != null && volPrev >= 0) am.setStreamVolume(AudioManager.STREAM_ALARM, volPrev, 0) } catch (_: Throwable) {}
                try { wl?.release() } catch (_: Throwable) {}
                sonando = false
            }
        }
    }
}
