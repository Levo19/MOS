package dev.levo.yapecaptor

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Una notificación de Yape lista para entregar. */
data class Captura(
    val notifKey: String,
    val texto: String,
    val titulo: String,
    val paquete: String,
    val tsMillis: Long,
    var intentos: Int = 0
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("notifKey", notifKey); put("texto", texto); put("titulo", titulo)
        put("paquete", paquete); put("tsMillis", tsMillis); put("intentos", intentos)
    }
    companion object {
        fun fromJson(o: JSONObject) = Captura(
            o.optString("notifKey"), o.optString("texto"), o.optString("titulo"),
            o.optString("paquete"), o.optLong("tsMillis"), o.optInt("intentos")
        )
    }
}

/**
 * Cola en disco. Un Yape capturado NO puede perderse porque el celular estaba sin señal:
 * es plata que entró y que el cierre de caja tiene que poder verificar. Se guarda primero,
 * se entrega después, y solo se borra cuando el servidor confirma.
 */
object Cola {
    private const val ARCHIVO = "cola_yapes.json"
    private const val TOPE = 500            // techo de seguridad: no crecer sin límite
    private val candado = Any()

    fun encolar(ctx: Context, c: Captura) = synchronized(candado) {
        val lista = leer(ctx)
        if (lista.any { it.notifKey == c.notifKey }) return   // ya estaba: no duplicar
        lista.add(c)
        while (lista.size > TOPE) lista.removeAt(0)
        escribir(ctx, lista)
    }

    fun pendientes(ctx: Context): List<Captura> = synchronized(candado) { leer(ctx) }

    fun quitar(ctx: Context, notifKey: String) = synchronized(candado) {
        val lista = leer(ctx)
        if (lista.removeAll { it.notifKey == notifKey }) escribir(ctx, lista)
    }

    fun marcarIntento(ctx: Context, notifKey: String) = synchronized(candado) {
        val lista = leer(ctx)
        lista.firstOrNull { it.notifKey == notifKey }?.let { it.intentos++ }
        escribir(ctx, lista)
    }

    fun tamano(ctx: Context): Int = synchronized(candado) { leer(ctx).size }

    private fun leer(ctx: Context): MutableList<Captura> {
        val f = java.io.File(ctx.filesDir, ARCHIVO)
        if (!f.exists()) return mutableListOf()
        return try {
            val arr = JSONArray(f.readText())
            MutableList(arr.length()) { Captura.fromJson(arr.getJSONObject(it)) }
        } catch (_: Throwable) { mutableListOf() }
    }

    private fun escribir(ctx: Context, lista: List<Captura>) {
        try {
            val arr = JSONArray()
            lista.forEach { arr.put(it.toJson()) }
            java.io.File(ctx.filesDir, ARCHIVO).writeText(arr.toString())
        } catch (_: Throwable) { }
    }
}
