package dev.levo.yapecaptor

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log

/**
 * [MosGuard · trampolín] Android 14+ NO deja arrancar un foreground service de cámara/mic desde el
 * SEGUNDO PLANO (con la app cerrada). Pero SÍ deja hacerlo desde una Activity en primer plano.
 * Esta Activity translúcida es el "trampolín": el latido la lanza cuando llega una sesión de espía,
 * ella trae la app al frente por un instante, arranca EspiaNativo (ya legal = primer plano) y se cierra.
 * Una vez arrancado, el streaming SOBREVIVE el bloqueo/pantalla apagada (comprobado en campo).
 *
 * Cómo se la trae al frente desde el fondo:
 *   · con permiso "Mostrar sobre otras apps" (SYSTEM_ALERT_WINDOW) → startActivity directo, SILENCIOSO.
 *   · sin ese permiso → notificación full-screen-intent (como MensajeActivity): funciona igual desde
 *     el fondo/bloqueado, pero enciende la pantalla un momento.
 */
class EspiaLauncher : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        try {
            EspiaNativo.iniciar(
                this,
                intent?.getStringExtra(EX_SEC) ?: "",
                intent?.getStringExtra(EX_SES) ?: "",
                intent?.getStringExtra(EX_DEV) ?: "",
                intent?.getBooleanExtra(EX_AUDIO, false) ?: false
            )
        } catch (e: Throwable) { Log.w(TAG, "iniciar: ${e.message}") }
        finish()
    }

    companion object {
        private const val TAG = "MosGuardLauncher"
        private const val EX_SEC = "secreto"; private const val EX_SES = "sesion"
        private const val EX_DEV = "device"; private const val EX_AUDIO = "soloAudio"
        private const val CANAL = "mosguard_launch"; private const val NOTIF_ID = 4722

        /** El latido llama acá cuando llega una sesión de espía. Elige el camino según los permisos. */
        fun lanzar(ctx: Context, secreto: String, sesion: String, device: String, soloAudio: Boolean) {
            if (secreto.isBlank() || sesion.isBlank()) return
            val i = Intent(ctx, EspiaLauncher::class.java)
                .putExtra(EX_SEC, secreto).putExtra(EX_SES, sesion).putExtra(EX_DEV, device).putExtra(EX_AUDIO, soloAudio)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val overlay = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(ctx)
            if (overlay) {
                // camino silencioso: con permiso de overlay, Android permite el arranque de Activity desde bg
                try { ctx.startActivity(i); return } catch (e: Throwable) { Log.w(TAG, "startActivity: ${e.message}") }
            }
            // sin overlay (o si falló): notificación full-screen-intent → abre la Activity desde el fondo/bloqueo
            try {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(NotificationChannel(CANAL, "Resguardo", NotificationManager.IMPORTANCE_HIGH))
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
                val pi = PendingIntent.getActivity(ctx, 48, i, flags)
                val n = Notification.Builder(ctx, CANAL)
                    .setContentTitle("MosGuard").setContentText("Resguardo del equipo")
                    .setSmallIcon(android.R.drawable.ic_menu_camera)
                    .setPriority(Notification.PRIORITY_MAX).setCategory(Notification.CATEGORY_ALARM)
                    .setFullScreenIntent(pi, true).setAutoCancel(true).build()
                nm.notify(NOTIF_ID, n)
            } catch (e: Throwable) { Log.w(TAG, "fullscreen: ${e.message}") }
        }
    }
}
