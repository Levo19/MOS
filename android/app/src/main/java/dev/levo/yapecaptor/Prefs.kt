package dev.levo.yapecaptor

import android.content.Context

/**
 * A dónde entregar. La URL y la clave anon vienen COMPILADAS: no son secretos — están a la
 * vista en el HTML de las tres apps web — y así en el celular no hay que tipear dos cadenas
 * larguísimas. Lo único que se pide es un código de 6 letras.
 */
object Backend {
    const val URL = "https://rzbzdeipbtqkzjqdchqk.supabase.co"
    const val ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k"
}

/** Lo que identifica a ESTE equipo. El secreto llega canjeando el código de emparejamiento. */
data class Config(
    val secreto: String,
    val nombre: String = "",
    val zona: String = ""
) {
    val supabaseUrl: String get() = Backend.URL
    val anonKey: String get() = Backend.ANON
    fun completa() = secreto.isNotBlank()
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
            sp.getString("secreto", "").orEmpty().trim(),
            sp.getString("nombre", "").orEmpty(),
            sp.getString("zona", "").orEmpty()
        )
    }

    fun guardar(ctx: Context, c: Config) {
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).edit()
            .putString("secreto", c.secreto.trim())
            .putString("nombre", c.nombre)
            .putString("zona", c.zona)
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

    // [MosGuard] último estado guard que devolvió el servidor (NORMAL|ROBADO)
    fun guardarGuardEstado(ctx: Context, e: String) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).edit().putString("guard", e).apply()

    fun guardEstado(ctx: Context) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).getString("guard", "NORMAL").orEmpty()

    // [883] ¿este equipo captura Yapes? (el dueño lo decide desde MOS; llega en el latido)
    fun guardarCaptura(ctx: Context, on: Boolean) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).edit().putBoolean("captura", on).apply()

    fun captura(ctx: Context) =
        ctx.getSharedPreferences(P, Context.MODE_PRIVATE).getBoolean("captura", true)
}
