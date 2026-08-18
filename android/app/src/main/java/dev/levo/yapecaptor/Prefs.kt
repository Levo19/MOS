package dev.levo.yapecaptor

import android.content.Context

/** Lo que el equipo necesita saber para entregar: a dónde y con qué secreto. */
data class Config(
    val supabaseUrl: String,
    val anonKey: String,
    val secreto: String
) {
    fun completa() = supabaseUrl.isNotBlank() && anonKey.isNotBlank() && secreto.isNotBlank()
}

/**
 * Guarda la configuración y el estado. El SECRETO del dispositivo se guarda acá; es
 * revocable desde el servidor (mos.yape_dispositivos.activo=false), así que si el celular
 * se pierde, se corta el acceso sin tocar el equipo.
 */
object Prefs {
    private const val P = "yape_captor"

    fun leer(ctx: Context): Config {
        val sp = ctx.getSharedPreferences(P, Context.MODE_PRIVATE)
        return Config(
            sp.getString("url", "").orEmpty().trim(),
            sp.getString("anon", "").orEmpty().trim(),
            sp.getString("secreto", "").orEmpty().trim()
        )
    }

    fun guardar(ctx: Context, c: Config) {
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).edit()
            .putString("url", c.supabaseUrl.trim())
            .putString("anon", c.anonKey.trim())
            .putString("secreto", c.secreto.trim())
            .apply()
    }

    fun marcarListenerVivo(ctx: Context, vivo: Boolean) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).edit().putBoolean("vivo", vivo).apply()

    fun listenerVivo(ctx: Context) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).getBoolean("vivo", false)

    fun marcarEntrega(ctx: Context) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).edit()
            .putLong("ultimaEntrega", System.currentTimeMillis())
            .putInt("total", total(ctx) + 1).apply()

    fun ultimaEntrega(ctx: Context) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).getLong("ultimaEntrega", 0L)

    fun total(ctx: Context) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).getInt("total", 0)

    fun guardarUltimoError(ctx: Context, e: String) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).edit().putString("err", e).apply()

    fun ultimoError(ctx: Context) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).getString("err", "").orEmpty()
}
