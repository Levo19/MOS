package dev.levo.yapecaptor

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent

/**
 * [MosGuard nativo] Administrador de dispositivo. Con esto activado (una vez, a mano, por seguridad):
 *   · BLOQUEO remoto: lockear la pantalla del equipo desde MOS (DevicePolicyManager.lockNow).
 *   · ANTI-DESINSTALACIÓN: el ladrón no puede desinstalar MosGuard sin ANTES desactivar el admin
 *     (y eso, tras el candado de la app, es fricción real).
 * La web no puede hacer nada de esto. lockNow() corre desde el hilo del latido (no necesita Activity).
 */
class GuardAdmin : DeviceAdminReceiver() {
    override fun onDisableRequested(context: Context, intent: Intent): CharSequence =
        "Si desactivás esto, MosGuard deja de proteger el equipo (bloqueo remoto y anti-robo)."

    companion object {
        fun componente(ctx: Context) = ComponentName(ctx, GuardAdmin::class.java)

        fun dpm(ctx: Context) = ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

        fun esAdmin(ctx: Context): Boolean =
            try { dpm(ctx).isAdminActive(componente(ctx)) } catch (_: Throwable) { false }

        /** Lanza el diálogo del sistema para activar el admin (desde el panel, con contexto de Activity). */
        fun pedirActivar(ctx: Context) {
            try {
                val i = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                    .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, componente(ctx))
                    .putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                        "Activá esto para poder BLOQUEAR el equipo a distancia y que no lo puedan desinstalar si te lo roban.")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(i)
            } catch (_: Throwable) {}
        }

        /** Bloquea la pantalla YA (si somos admin). Corre desde cualquier hilo. */
        fun bloquear(ctx: Context): Boolean =
            try { if (esAdmin(ctx)) { dpm(ctx).lockNow(); true } else false } catch (_: Throwable) { false }
    }
}
