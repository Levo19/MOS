package dev.levo.yapecaptor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * [MosGuard nativo] Mensaje a PANTALLA COMPLETA en el equipo ("Este equipo está rastreado, devuélvelo").
 * Se muestra por encima del lock. Se lanza vía notificación con full-screen-intent (así aparece aunque
 * el equipo esté de fondo/bloqueado; en Android 14 no-calling puede caer a heads-up = igual se ve).
 */
class MensajeActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        val txt = intent?.getStringExtra(EXTRA_TXT).orEmpty()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            setBackgroundColor(0xFF0B2E2A.toInt()); setPadding(dp(28), dp(28), dp(28), dp(28))
        }
        root.addView(TextView(this).apply { text = "🛡️"; textSize = 56f; gravity = Gravity.CENTER })
        root.addView(TextView(this).apply {
            text = txt; textSize = 22f; setTextColor(Color.WHITE); gravity = Gravity.CENTER
            setPadding(0, dp(20), 0, 0); setLineSpacing(dp(4).toFloat(), 1f)
        })
        setContentView(root)
        // se cierra sola a los 2 min (el mensaje ya cumplió)
        root.postDelayed({ try { finish() } catch (_: Throwable) {} }, 120_000L)
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val EXTRA_TXT = "texto"
        private const val CANAL = "mosguard_mensaje"
        private const val NOTIF_ID = 4721

        /** Muestra el mensaje: notificación de máxima prioridad con full-screen-intent → la Activity. */
        fun mostrar(ctx: Context, texto: String) {
            if (texto.isBlank()) return
            try {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(NotificationChannel(CANAL, "Avisos MosGuard", NotificationManager.IMPORTANCE_HIGH))
                }
                val i = Intent(ctx, MensajeActivity::class.java)
                    .putExtra(EXTRA_TXT, texto)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
                val pi = PendingIntent.getActivity(ctx, 47, i, flags)
                val n = Notification.Builder(ctx, CANAL)
                    .setContentTitle("🛡️ MosGuard").setContentText(texto)
                    .setSmallIcon(android.R.drawable.ic_dialog_alert)
                    .setPriority(Notification.PRIORITY_MAX).setCategory(Notification.CATEGORY_ALARM)
                    .setFullScreenIntent(pi, true).setAutoCancel(true).build()
                nm.notify(NOTIF_ID, n)
            } catch (_: Throwable) {}
        }
    }
}
