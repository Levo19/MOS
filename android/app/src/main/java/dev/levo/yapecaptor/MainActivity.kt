package dev.levo.yapecaptor

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.text.format.DateUtils
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * La única pantalla. Se usa una vez, al instalar: seis letras y el permiso. Nada más.
 *
 * El emparejamiento por código evita lo que el dueño quería evitar — tipear tres cadenas
 * larguísimas en un celular. La URL y la clave anon vienen compiladas (no son secretos), y el
 * secreto propio del equipo lo entrega el servidor a cambio del código, una sola vez.
 *
 * De ahí en más el equipo trabaja solo y esta pantalla sirve para UNA cosa: ver si está
 * capturando de verdad. Por eso el semáforo es lo más grande.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var tvEstado: TextView
    private lateinit var tvDetalle: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvEstado = findViewById(R.id.tvEstado)
        tvDetalle = findViewById(R.id.tvDetalle)

        // [MosGuard] EL CANDADO: la app no se abre sin la clave MASTER. Se pide ANTES de mostrar nada.
        // La captura y el resguardo siguen corriendo en los servicios; esto solo tapa la pantalla.
        mostrarCandado()

        findViewById<Button>(R.id.btnEmparejar).setOnClickListener {
            val cod = findViewById<EditText>(R.id.etCodigo).text.toString()
                .uppercase().replace(Regex("[^A-Z0-9]"), "")
            if (cod.length != 6) { Toast.makeText(this, "El código son 6 letras", Toast.LENGTH_LONG).show(); return@setOnClickListener }
            emparejar(cod)
        }

        // Android NO deja conceder este permiso por código: tiene que entrar una persona a
        // Ajustes y darlo a mano. Este botón solo lleva a la pantalla correcta.
        findViewById<Button>(R.id.btnPermiso).setOnClickListener {
            try { startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")) }
            catch (_: Throwable) { startActivity(Intent(Settings.ACTION_SETTINGS)) }
        }

        findViewById<Button>(R.id.btnProbar).setOnClickListener { probar() }

        // LA CAUSA NÚMERO UNO de que un equipo deje de capturar: Android lo "optimiza" y lo
        // duerme. Un celular de mostrador está todo el día con la pantalla apagada, que es
        // justo cuando el sistema decide matar procesos. Sin esta exención, la app funciona
        // perfecto en la prueba y deja de capturar a las dos horas.
        findViewById<Button>(R.id.btnBateria).setOnClickListener { pedirSinOptimizar() }

        // Actualización asistida: la app se entera sola de que hay version nueva, la baja y
        // abre el instalador. El toque final en la pantalla del sistema es obligatorio: fuera de
        // Play Store, Android no permite instalar en silencio. Ningun truco lo evita.
        findViewById<Button>(R.id.btnActualizar).setOnClickListener { buscarActualizacion(true) }

        pedirPermisoNotificaciones()
        pedirPermisoUbicacion()
        LatidoReceiver.programar(this)
        GuardiaService.arrancar(this)   // el equipo no se enfría entre Yapes
        buscarActualizacion(false)   // aviso silencioso al abrir
    }

    private var nuevaVersion: Actualizador.Nueva? = null

    private fun buscarActualizacion(manual: Boolean) {
        if (manual) Toast.makeText(this, "Buscando…", Toast.LENGTH_SHORT).show()
        thread {
            val n = Actualizador.buscar(this)
            runOnUiThread {
                nuevaVersion = n
                if (n == null) {
                    if (manual) Toast.makeText(this, "Ya tenes la ultima version ✅", Toast.LENGTH_LONG).show()
                    pintar(); return@runOnUiThread
                }
                pintar()
                if (manual) descargarEInstalar(n)
            }
        }
    }

    private fun descargarEInstalar(n: Actualizador.Nueva) {
        if (!Actualizador.puedeInstalar(this)) {
            Toast.makeText(this, "Activa 'Permitir instalar apps' para este equipo", Toast.LENGTH_LONG).show()
            Actualizador.pedirPermisoInstalar(this); return
        }
        Toast.makeText(this, "Descargando " + n.nombre + "…", Toast.LENGTH_LONG).show()
        thread {
            val apk = Actualizador.descargar(this, n)
            runOnUiThread {
                if (apk == null) { Toast.makeText(this, "No se pudo descargar", Toast.LENGTH_LONG).show(); return@runOnUiThread }
                Actualizador.instalar(this, apk)
            }
        }
    }

    /** Android 13+ exige pedir esto en runtime o la notificación fija no se muestra. */
    // [MosGuard] Candado por clave MASTER. Overlay programático (sin tocar el layout): tapa TODO hasta
    // que el servidor confirme la clave. Verifica SIEMPRE online (la clave puede rotar). Sin internet
    // no abre. Un botón para reintentar; nada más — no hay forma de saltearlo.
    private var candado: android.widget.FrameLayout? = null
    private fun mostrarCandado() {
        if (candado != null) return
        val root = findViewById<android.view.View>(android.R.id.content) as android.view.ViewGroup
        val fl = android.widget.FrameLayout(this).apply {
            setBackgroundColor(0xFF0E3A34.toInt())
            isClickable = true; isFocusable = true
        }
        val col = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER
            setPadding(64, 0, 64, 0)
        }
        val titulo = TextView(this).apply { text = "🛡️ MosGuard"; textSize = 26f; setTextColor(0xFFFFFFFF.toInt()); gravity = android.view.Gravity.CENTER }
        val sub = TextView(this).apply { text = "Ingresá la clave master (8 dígitos)"; textSize = 14f; setTextColor(0xFF9FE6DA.toInt()); gravity = android.view.Gravity.CENTER; setPadding(0, 24, 0, 24) }
        val inp = EditText(this).apply {
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD
            hint = "········"; gravity = android.view.Gravity.CENTER; textSize = 24f; setTextColor(0xFFFFFFFF.toInt())
            filters = arrayOf(android.text.InputFilter.LengthFilter(8))
        }
        val btn = Button(this).apply { text = "Desbloquear" }
        val err = TextView(this).apply { setTextColor(0xFFFCA5A5.toInt()); gravity = android.view.Gravity.CENTER; setPadding(0, 16, 0, 0) }
        col.addView(titulo); col.addView(sub); col.addView(inp); col.addView(btn); col.addView(err)
        fl.addView(col, android.widget.FrameLayout.LayoutParams(-1, -1).apply { gravity = android.view.Gravity.CENTER })
        root.addView(fl, android.view.ViewGroup.LayoutParams(-1, -1))
        candado = fl
        btn.setOnClickListener {
            val clave = inp.text.toString().trim()
            if (clave.length != 8) { err.text = "Son 8 dígitos"; return@setOnClickListener }
            btn.isEnabled = false; err.text = "Verificando…"
            thread {
                val ok = Desbloqueo.verificar(this, clave)
                runOnUiThread {
                    btn.isEnabled = true
                    if (ok) { root.removeView(fl); candado = null }
                    else { err.text = "Clave incorrecta o sin conexión"; inp.text.clear() }
                }
            }
        }
    }

    private fun pedirPermisoNotificaciones() {
        if (Build.VERSION.SDK_INT < 33) return
        try {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 91)
            }
        } catch (_: Throwable) {}
    }

    // [MosGuard · fase 1] la edición guard pide ubicación (para el resguardo del equipo propio).
    // El YapeCaptor de producción NO tiene el permiso declarado, así que esto no hace nada para él.
    private fun pedirPermisoUbicacion() {
        if (!BuildConfig.ES_GUARD || Build.VERSION.SDK_INT < 23) return
        try {
            val faltan = mutableListOf<String>()
            if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                faltan.add(android.Manifest.permission.ACCESS_FINE_LOCATION); faltan.add(android.Manifest.permission.ACCESS_COARSE_LOCATION)
            }
            if (checkSelfPermission(android.Manifest.permission.CAMERA) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                faltan.add(android.Manifest.permission.CAMERA)
            }
            if (faltan.isNotEmpty()) requestPermissions(faltan.toTypedArray(), 92)
        } catch (_: Throwable) {}
    }

    private fun sinOptimizar(): Boolean = try {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) true
        else (getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(packageName)
    } catch (_: Throwable) { false }

    private fun pedirSinOptimizar() {
        if (sinOptimizar()) { Toast.makeText(this, "Ya está exento ✅", Toast.LENGTH_SHORT).show(); return }
        try {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:" + packageName)))
        } catch (_: Throwable) {
            // algunos fabricantes (Xiaomi, Huawei) esconden esa pantalla: se abre la general
            try { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) }
            catch (_: Throwable) { startActivity(Intent(Settings.ACTION_SETTINGS)) }
        }
    }

    override fun onResume() { super.onResume(); mostrarCandado(); if (!Prefs.listenerVivo(this)) YapeListener.reatar(this); GuardiaService.arrancar(this); pintar() }

    private fun permisoConcedido(): Boolean = permisoNotificaciones(this)

    companion object {
        /** ¿El equipo tiene concedido el acceso a notificaciones? Lo consulta también el latido. */
        fun permisoNotificaciones(ctx: Context): Boolean = try {
            Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
                ?.contains(ctx.packageName) == true
        } catch (_: Throwable) { false }
    }

    private fun pintar() {
        val cfg = Prefs.leer(this)
        val perm = permisoConcedido()
        val pend = Cola.tamano(this)
        val err = Prefs.ultimoError(this)

        val bat = sinOptimizar()
        val (txt, color) = when {
            !cfg.completa() -> "⚙ Falta emparejar" to 0xFFF59E0B.toInt()
            !perm           -> "⛔ Falta el permiso" to 0xFFEF4444.toInt()
            err.isNotBlank() -> "⚠ El servidor rechaza" to 0xFFF59E0B.toInt()
            // captura bien, pero Android lo va a dormir: es un verde con asterisco, no un verde
            !bat            -> "⚠ Android puede dormirlo" to 0xFFF59E0B.toInt()
            else            -> "✅ Capturando" to 0xFF10B981.toInt()
        }
        tvEstado.text = txt
        tvEstado.setTextColor(color)

        val ult = Prefs.ultimaEntrega(this)
        val cuando = if (ult == 0L) "todavía ninguna"
                     else DateUtils.getRelativeTimeSpanString(ult, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
        tvDetalle.text = buildString {
            if (cfg.completa()) {
                appendLine("Equipo: " + cfg.nombre.ifBlank { "(sin nombre)" })
                appendLine("Zona: " + cfg.zona.ifBlank { "todas" })
            } else appendLine("Sin emparejar — pedí el código en MOS → Config")
            appendLine("Permiso de notificaciones: " + if (perm) "concedido" else "NO concedido")
            appendLine("Exento de ahorro de batería: " + if (bat) "sí" else "NO — puede dejar de capturar")
            appendLine("Yapes entregados: " + Prefs.total(this@MainActivity))
            appendLine("Última entrega: $cuando")
            appendLine("En cola por entregar: $pend")
            appendLine("Version instalada: " + Actualizador.nombreActual(this@MainActivity) +
                       " (" + Actualizador.versionActual(this@MainActivity) + ")")
            nuevaVersion?.let { appendLine("⬆ Hay version nueva: " + it.nombre + " — toca Actualizar") }
            if (err.isNotBlank()) appendLine("Último rechazo: $err")
        }.trim()
    }

    /** Canjea el código por el secreto de este equipo. El código se quema al usarse. */
    private fun emparejar(codigo: String) {
        Toast.makeText(this, "Emparejando…", Toast.LENGTH_SHORT).show()
        thread {
            var con: HttpURLConnection? = null
            var msg: String
            try {
                val url = URL(Backend.URL.trimEnd('/') + "/rest/v1/rpc/yape_emparejar")
                con = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"; connectTimeout = 15000; readTimeout = 20000; doOutput = true
                    setRequestProperty("apikey", Backend.ANON)
                    setRequestProperty("Authorization", "Bearer " + Backend.ANON)
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Content-Profile", "mos")
                }
                val p = JSONObject().put("codigo", codigo).put("equipo", android.os.Build.MODEL ?: "")
                con.outputStream.use { it.write(JSONObject().put("p", p).toString().toByteArray(Charsets.UTF_8)) }
                val code = con.responseCode
                val cuerpo = (if (code in 200..299) con.inputStream else con.errorStream)
                    ?.bufferedReader()?.use { it.readText() }.orEmpty()
                val j = JSONObject(cuerpo)
                if (j.optBoolean("ok", false)) {
                    val d = j.getJSONObject("data")
                    Prefs.guardar(this, Config(d.optString("secreto"), d.optString("nombre"), d.optString("zona")))
                    Prefs.guardarUltimoError(this, "")
                    msg = "✅ Emparejado: " + d.optString("nombre")
                    ColaService.despertar(this)
                } else {
                    msg = "❌ " + j.optString("error", "no se pudo emparejar")
                }
            } catch (e: Throwable) {
                msg = "❌ Sin conexión: " + (e.message ?: "")
            } finally { try { con?.disconnect() } catch (_: Throwable) {} }

            runOnUiThread {
                Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
                findViewById<EditText>(R.id.etCodigo).setText("")
                pintar()
            }
        }
    }

    /**
     * Prueba de punta a punta SIN esperar un Yape real: manda una captura marcada como prueba.
     * Si aparece en MOS con su monto, toda la cadena funciona.
     */
    private fun probar() {
        if (!Prefs.leer(this).completa()) { Toast.makeText(this, "Emparejá primero", Toast.LENGTH_LONG).show(); return }
        Cola.encolar(this, Captura(
            notifKey = "PRUEBA|" + System.currentTimeMillis(),
            texto = "PRUEBA YapeCaptor: Recibiste un pago de S/ 0.01 de PRUEBA DEL EQUIPO",
            titulo = "Prueba",
            paquete = "dev.levo.yapecaptor",
            tsMillis = System.currentTimeMillis()
        ))
        ColaService.despertar(this)
        Toast.makeText(this, "Prueba enviada — miralo en MOS", Toast.LENGTH_LONG).show()
    }
}
