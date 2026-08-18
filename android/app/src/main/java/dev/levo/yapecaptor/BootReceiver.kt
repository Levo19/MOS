package dev.levo.yapecaptor

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Al reiniciar el celular, la cola puede tener capturas sin entregar. Se despierta el
 * servicio para vaciarla; el listener de notificaciones Android lo re-ata solo.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val ctx = context ?: return
        if (Cola.tamano(ctx) > 0) ColaService.despertar(ctx)
    }
}
