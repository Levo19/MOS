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
 * La única pantalla, detrás del candado de la clave MASTER. Ya no se "empareja" nada: el equipo
 * se REGISTRA solo al desbloquear con la clave (autoRegistrar), así que esta pantalla dejó de ser
 * un formulario de instalación y pasó a ser un PANEL DE ESTADO: de un vistazo se ve si el equipo
 * está conectado a MOS, si captura Yapes, si la cámara/ubicación/batería están listas — y cada
 * fila que le falte algo se TOCA para activarlo ahí mismo. Simple y útil en campo.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var tvEstado: TextView
    private lateinit var tvDetalle: TextView
    private lateinit var listaSalud: android.widget.LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvEstado = findViewById(R.id.tvEstado)
        tvDetalle = findViewById(R.id.tvDetalle)
        listaSalud = findViewById(R.id.listaSalud)

        // [MosGuard] EL CANDADO: la app no se abre sin la clave MASTER. Se pide ANTES de mostrar nada.
        // La captura y el resguardo siguen corriendo en los servicios; esto solo tapa la pantalla.
        // Al desbloquear, si el equipo aún no tiene secreto, se auto-registra con esa misma clave.
        mostrarCandado()

        // Actualización asistida: la app se entera sola de que hay version nueva, la baja y
        // abre el instalador. El toque final en la pantalla del sistema es obligatorio: fuera de
        // Play Store, Android no permite instalar en silencio. Ningun truco lo evita.
        findViewById<Button>(R.id.btnActualizar).setOnClickListener { buscarActualizacion(true) }
        findViewById<Button>(R.id.btnProbar).setOnClickListener { probar() }

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
    private val _dpi get() = resources.displayMetrics.density
    private fun dp(v: Int) = (v * _dpi).toInt()

    // círculo/redondeado programático (sin XML de drawables)
    private fun redondo(color: Int, radio: Int): android.graphics.drawable.GradientDrawable =
        android.graphics.drawable.GradientDrawable().apply { setColor(color); cornerRadius = dp(radio).toFloat() }

    private fun mostrarCandado() {
        if (candado != null) return
        val root = findViewById<android.view.View>(android.R.id.content) as android.view.ViewGroup
        val fl = android.widget.FrameLayout(this).apply { setBackgroundColor(0xFF0B2E2A.toInt()); isClickable = true; isFocusable = true }

        val col = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL; gravity = android.view.Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(48), dp(28), dp(28))
        }
        val escudo = TextView(this).apply { text = "🛡️"; textSize = 44f; gravity = android.view.Gravity.CENTER }
        val titulo = TextView(this).apply { text = "MosGuard"; textSize = 24f; setTextColor(0xFFFFFFFF.toInt()); gravity = android.view.Gravity.CENTER; typeface = android.graphics.Typeface.DEFAULT_BOLD; setPadding(0, dp(6), 0, 0) }
        val sub = TextView(this).apply { text = "Clave master"; textSize = 13f; setTextColor(0xFF7FD6C8.toInt()); gravity = android.view.Gravity.CENTER; letterSpacing = 0.08f; setPadding(0, dp(4), 0, dp(26)) }

        // 8 puntos que se llenan
        val puntos = android.widget.LinearLayout(this).apply { orientation = android.widget.LinearLayout.HORIZONTAL; gravity = android.view.Gravity.CENTER }
        val dots = ArrayList<TextView>()
        for (i in 0 until 8) {
            val d = TextView(this).apply { background = redondo(0x33FFFFFF, 99); width = dp(13); height = dp(13) }
            val lp = android.widget.LinearLayout.LayoutParams(dp(13), dp(13)).apply { setMargins(dp(6), 0, dp(6), 0) }
            puntos.addView(d, lp); dots.add(d)
        }
        val err = TextView(this).apply { setTextColor(0xFFFCA5A5.toInt()); gravity = android.view.Gravity.CENTER; textSize = 12f; setPadding(0, dp(16), 0, dp(8)); height = dp(38) }

        col.addView(escudo); col.addView(titulo); col.addView(sub); col.addView(puntos); col.addView(err)

        // ── el teclado numérico propio (sin teclado del sistema) ──
        val clave = StringBuilder()
        var verificando = false
        val pinta = { for (i in 0 until 8) dots[i].background = redondo(if (i < clave.length) 0xFF2DE3C8.toInt() else 0x33FFFFFF, 99) }
        var onDigito: (String) -> Unit = {}
        var onBorrar: () -> Unit = {}

        fun tecla(txt: String, accion: () -> Unit): TextView = TextView(this).apply {
            text = txt; textSize = 26f; setTextColor(0xFFEFFFFB.toInt()); gravity = android.view.Gravity.CENTER
            background = redondo(0x14FFFFFF, 99)
            isClickable = true
            setOnClickListener { try { performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY) } catch (_: Throwable) {}; accion() }
        }

        val grid = android.widget.GridLayout(this).apply { columnCount = 3; rowCount = 4; setPadding(0, dp(14), 0, 0) }
        val cel = dp(74); val gap = dp(9)
        val orden = listOf("1","2","3","4","5","6","7","8","9","","0","⌫")
        for ((idx, t) in orden.withIndex()) {
            val v: android.view.View = when (t) {
                "" -> android.view.View(this)
                "⌫" -> tecla("⌫") { onBorrar() }
                else -> tecla(t) { onDigito(t) }
            }
            val lp = android.widget.GridLayout.LayoutParams().apply {
                width = cel; height = cel; setMargins(gap, gap, gap, gap)
                rowSpec = android.widget.GridLayout.spec(idx / 3); columnSpec = android.widget.GridLayout.spec(idx % 3)
            }
            grid.addView(v, lp)
        }
        col.addView(grid)

        fl.addView(col, android.widget.FrameLayout.LayoutParams(-2, -2).apply { gravity = android.view.Gravity.CENTER })
        root.addView(fl, android.view.ViewGroup.LayoutParams(-1, -1))
        candado = fl
        pinta()

        val verificar = {
            verificando = true; err.setTextColor(0xFF7FD6C8.toInt()); err.text = "Verificando…"
            val c = clave.toString()
            thread {
                val ok = Desbloqueo.verificar(this, c)
                // [MosGuard auto-registro] si desbloqueó (clave master OK) y el equipo aún NO tiene secreto, se
                // registra SOLO con esa misma clave — sin código de emparejamiento. Aditivo: un equipo que YA tiene
                // secreto (los de producción ZONA-1/2) no entra acá → intactos.
                var registroNuevo = false
                if (ok && !Prefs.leer(this).completa()) { try { registroNuevo = autoRegistrar(c) } catch (_: Throwable) {} }
                runOnUiThread {
                    verificando = false
                    if (ok) {
                        root.removeView(fl); candado = null; pintar()
                        // recién registrado → ofrecer bautizarlo (así se ubica al toque en el panel MOS)
                        if (registroNuevo) pedirNombre()
                    }
                    else {
                        err.setTextColor(0xFFFCA5A5.toInt()); err.text = "Clave incorrecta o sin conexión"
                        clave.setLength(0); pinta()
                        try { puntos.animate().translationX(dp(8).toFloat()).setDuration(60).withEndAction { puntos.animate().translationX(dp(-8).toFloat()).setDuration(60).withEndAction { puntos.translationX = 0f } } } catch (_: Throwable) {}
                    }
                }
            }
        }
        onDigito = d@{ dgt ->
            if (verificando || clave.length >= 8) return@d
            if (err.text.isNotEmpty()) err.text = ""
            clave.append(dgt); pinta()
            if (clave.length == 8) verificar()   // 8 dígitos → verifica solo
        }
        onBorrar = b@{ if (verificando || clave.isEmpty()) return@b; clave.deleteCharAt(clave.length - 1); pinta() }
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
            // micrófono: el "Ver + escuchar" pide audio; sin este permiso getUserMedia falla / no hay audio.
            if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                faltan.add(android.Manifest.permission.RECORD_AUDIO)
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

    // repinta el panel apenas se concede/deniega un permiso (la fila pasa a ✓ sin salir de la app)
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        try { pintar() } catch (_: Throwable) {}
        if (requestCode == 92) GuardiaService.arrancar(this)   // con ubicación/cámara ya puede resguardar
    }

    private fun permisoConcedido(): Boolean = permisoNotificaciones(this)

    companion object {
        /** ¿El equipo tiene concedido el acceso a notificaciones? Lo consulta también el latido. */
        fun permisoNotificaciones(ctx: Context): Boolean = try {
            Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
                ?.contains(ctx.packageName) == true
        } catch (_: Throwable) { false }
    }

    // ── helpers de permiso (para la checklist de salud) ──
    private fun tienePermiso(p: String): Boolean = try {
        Build.VERSION.SDK_INT < 23 || checkSelfPermission(p) == android.content.pm.PackageManager.PERMISSION_GRANTED
    } catch (_: Throwable) { false }
    private fun tieneCamara() = tienePermiso(android.Manifest.permission.CAMERA)
    private fun tieneUbicacion() = tienePermiso(android.Manifest.permission.ACCESS_FINE_LOCATION)
    private fun tieneMic() = tienePermiso(android.Manifest.permission.RECORD_AUDIO)

    private fun abrirAjustesNotif() {
        try { startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")) }
        catch (_: Throwable) { startActivity(Intent(Settings.ACTION_SETTINGS)) }
    }

    /** Ajustes de ESTA app (permisos Cámara/Ubicación se activan a mano acá cuando el diálogo ya no aparece). */
    private fun abrirAjustesApp() {
        try { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + packageName))) }
        catch (_: Throwable) { startActivity(Intent(Settings.ACTION_SETTINGS)) }
    }

    /** [cámara/ubicación] Sin estos permisos NADA de vigilancia anda (ni GPS, ni foto, ni ver en vivo).
     *  Al tocar la fila: si Android todavía muestra el diálogo, lo pide; si ya fue denegado permanente,
     *  lleva a Ajustes de la app (donde SÍ se puede activar a mano). */
    private fun activarCamaraUbicacion() {
        val faltan = mutableListOf<String>()
        if (!tieneCamara()) faltan.add(android.Manifest.permission.CAMERA)
        if (!tieneMic()) faltan.add(android.Manifest.permission.RECORD_AUDIO)
        if (!tieneUbicacion()) { faltan.add(android.Manifest.permission.ACCESS_FINE_LOCATION); faltan.add(android.Manifest.permission.ACCESS_COARSE_LOCATION) }
        if (faltan.isEmpty()) return
        val yaNoPregunta = Build.VERSION.SDK_INT >= 23 && faltan.all { !shouldShowRequestPermissionRationale(it) }
        if (yaNoPregunta) {
            Toast.makeText(this, "Activá Cámara y Ubicación en Permisos", Toast.LENGTH_LONG).show()
            abrirAjustesApp()
        } else if (Build.VERSION.SDK_INT >= 23) {
            requestPermissions(faltan.toTypedArray(), 92)
        }
    }

    /**
     * PANEL DE ESTADO. Reconstruye el semáforo grande + la checklist tocable cada vez.
     * Cada fila: emoji, qué es, y su estado; si le falta algo, se TOCA y salta a activarlo.
     */
    private fun pintar() {
        val cfg = Prefs.leer(this)
        val reg  = cfg.completa()
        val notif = permisoConcedido()
        val cam = tieneCamara()
        val mic = tieneMic()
        val ubi = tieneUbicacion()
        val bat = sinOptimizar()
        val err = Prefs.ultimoError(this)

        // semáforo general
        val faltan = listOf(notif, cam, mic, ubi, bat).count { !it }
        val (txt, color) = when {
            !reg  -> "🔌 Conectá el equipo" to 0xFFEF4444.toInt()
            err.isNotBlank() -> "⚠ El servidor rechaza" to 0xFFF59E0B.toInt()
            faltan == 0 -> "🛡️ Equipo protegido" to 0xFF10B981.toInt()
            else  -> "⚠ Falta activar $faltan" to 0xFFF59E0B.toInt()
        }
        tvEstado.text = txt
        tvEstado.setTextColor(color)

        // ── checklist de salud ──
        listaSalud.removeAllViews()
        val VERDE = 0xFF10B981.toInt(); val AMBAR = 0xFFF59E0B.toInt(); val ROJO = 0xFFEF4444.toInt()

        // 1) conexión a MOS (el equipo tiene secreto = está registrado y late en el panel)
        if (reg) filaSalud("🔗", cfg.nombre.ifBlank { "Conectado a MOS" }, "Conectado · tocá para renombrar", VERDE, "✎") { pedirNombre() }
        else     filaSalud("🔗", "Sin conectar", "Tocá para reintentar la conexión", ROJO, "›") { reconectar() }

        // 2) captura de Yapes (permiso de notificaciones — lo que el dueño quería ver)
        if (notif) filaSalud("🔔", "Captura de Yapes", "Escuchando notificaciones", VERDE, "✓", null)
        else       filaSalud("🔔", "Captura de Yapes", "Falta el permiso · tocá para activar", AMBAR, "›") { abrirAjustesNotif() }

        // 3) cámara (vigilancia en vivo) — SIN esto no hay foto ni "ver en vivo"
        if (cam) filaSalud("📷", "Cámara", "Lista para vigilancia", VERDE, "✓", null)
        else     filaSalud("📷", "Cámara", "Falta el permiso · tocá para activar", AMBAR, "›") { activarCamaraUbicacion() }

        // 3b) micrófono — para el "Ver + escuchar" (audio en vivo)
        if (mic) filaSalud("🎤", "Micrófono", "Audio en vivo listo", VERDE, "✓", null)
        else     filaSalud("🎤", "Micrófono", "Falta el permiso · tocá para activar", AMBAR, "›") { activarCamaraUbicacion() }

        // 4) ubicación (dónde está el equipo)
        if (ubi) filaSalud("📍", "Ubicación", "GPS activo", VERDE, "✓", null)
        else     filaSalud("📍", "Ubicación", "Falta el permiso · tocá para activar", AMBAR, "›") { activarCamaraUbicacion() }

        // 5) batería (que Android no lo duerma con la pantalla apagada)
        if (bat) filaSalud("🔋", "Siempre activo", "Android no lo va a dormir", VERDE, "✓", null)
        else     filaSalud("🔋", "Siempre activo", "Android puede dormirlo · tocá", AMBAR, "›") { pedirSinOptimizar() }

        // 6) bloqueo remoto + anti-desinstalación (opcional, Device Admin) — no cuenta en el semáforo
        if (GuardAdmin.esAdmin(this)) filaSalud("🔒", "Bloqueo remoto", "Administrador activo · no se puede desinstalar", VERDE, "✓", null)
        else                          filaSalud("🔒", "Bloqueo remoto", "Tocá para activar (lockear a distancia + anti-robo)", AMBAR, "›") { GuardAdmin.pedirActivar(this) }

        // detalle discreto abajo: specs del equipo (los que ve también el panel MOS) + versión
        val ult = Prefs.ultimaEntrega(this)
        val cuando = if (ult == 0L) "todavía ninguna"
                     else DateUtils.getRelativeTimeSpanString(ult, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
        val marca = (android.os.Build.MANUFACTURER ?: "").replaceFirstChar { it.uppercase() }
        tvDetalle.text = buildString {
            appendLine("Equipo: " + marca + " " + (android.os.Build.MODEL ?: "") + " · Android " + (android.os.Build.VERSION.RELEASE ?: ""))
            if (reg) appendLine("Zona: " + cfg.zona.ifBlank { "sin asignar (se define en MOS)" })
            appendLine("Yapes entregados: " + Prefs.total(this@MainActivity) + " · última: " + cuando)
            appendLine("Version: " + Actualizador.nombreActual(this@MainActivity) +
                       " (" + Actualizador.versionActual(this@MainActivity) + ")")
            nuevaVersion?.let { appendLine("⬆ Hay version nueva: " + it.nombre + " — toca Actualizar") }
            if (err.isNotBlank()) appendLine("Último rechazo: $err")
        }.trim()
    }

    /** Una fila de la checklist de salud: emoji + qué es + estado, con un glifo a la derecha
     *  (✓ hecho · › hay que tocar · ✎ renombrar). Si trae onTap, la fila entera es tocable. */
    private fun filaSalud(emoji: String, titulo: String, estado: String, color: Int, glifo: String, onTap: (() -> Unit)?) {
        val row = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            background = redondo(0xFF0F1B2E.toInt(), 12)
            setPadding(dp(14), dp(12), dp(14), dp(12))
            if (onTap != null) { isClickable = true; setOnClickListener { onTap() } }
        }
        val ico = TextView(this).apply { text = emoji; textSize = 20f; setPadding(0, 0, dp(12), 0) }
        val medio = android.widget.LinearLayout(this).apply { orientation = android.widget.LinearLayout.VERTICAL }
        medio.addView(TextView(this).apply { text = titulo; textSize = 14f; setTextColor(0xFFE2E8F0.toInt()); typeface = android.graphics.Typeface.DEFAULT_BOLD })
        medio.addView(TextView(this).apply { text = estado; textSize = 12f; setTextColor(color); setPadding(0, dp(2), 0, 0) })
        row.addView(ico)
        row.addView(medio, android.widget.LinearLayout.LayoutParams(0, -2, 1f))
        row.addView(TextView(this).apply { text = glifo; textSize = 18f; setTextColor(color); typeface = android.graphics.Typeface.DEFAULT_BOLD })
        val lp = android.widget.LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) }
        listaSalud.addView(row, lp)
    }

    /** [reconexión] Sin secreto (el auto-registro no llegó a completarse): re-muestra el candado; al
     *  desbloquear con la clave MASTER, autoRegistrar corre de nuevo y el equipo queda conectado. */
    private fun reconectar() {
        Toast.makeText(this, "Ingresá la clave master para conectar", Toast.LENGTH_SHORT).show()
        mostrarCandado()
    }

    /** [MosGuard auto-registro] Sin código: la clave MASTER recién verificada en el desbloqueo AUTORIZA el registro.
     *  Identidad estable = ANDROID_ID (sobrevive reinstalación). El equipo nace solo como RESGUARDO (Yapes OFF);
     *  el Yape de una zona se le asigna después desde el panel MOS. Corre en el hilo del desbloqueo (ya es background). */
    private fun autoRegistrar(clave: String): Boolean {
        var con: HttpURLConnection? = null
        try {
            val uuid = try { Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: "" } catch (_: Throwable) { "" }
            if (uuid.isBlank()) return false
            con = (URL(Backend.URL.trimEnd('/') + "/rest/v1/rpc/yape_guard_autoregistrar").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"; connectTimeout = 12000; readTimeout = 15000; doOutput = true
                setRequestProperty("apikey", Backend.ANON)
                setRequestProperty("Authorization", "Bearer " + Backend.ANON)
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Content-Profile", "mos")
            }
            // specs para el panel MOS: marca (fabricante) + modelo + versión de Android
            val marca = (android.os.Build.MANUFACTURER ?: "").replaceFirstChar { it.uppercase() }
            val p = JSONObject().put("clave", clave).put("deviceUuid", uuid)
                .put("modelo", android.os.Build.MODEL ?: "")
                .put("marca", marca)
                .put("so", "Android " + (android.os.Build.VERSION.RELEASE ?: ""))
            con.outputStream.use { it.write(JSONObject().put("p", p).toString().toByteArray(Charsets.UTF_8)) }
            if (con.responseCode !in 200..299) return false
            val r = JSONObject(con.inputStream.bufferedReader().use { it.readText() })
            if (r.optBoolean("ok", false)) {
                val d = r.optJSONObject("data") ?: return false
                Prefs.guardar(this, Config(d.optString("secreto"), d.optString("nombre"), d.optString("zona")))
                Prefs.guardarUltimoError(this, "")
                ColaService.despertar(this)   // arranca el latido → aparece en el panel enseguida
                return true
            }
        } catch (_: Throwable) {
        } finally { try { con?.disconnect() } catch (_: Throwable) {} }
        return false
    }

    /** [nombre] Diálogo para bautizar el equipo (ej "Caja Zona 3") → así se ubica al toque en el panel MOS.
     *  Se ofrece solo al registrarse por primera vez, y también al tocar la fila "Conectado". */
    private fun pedirNombre() {
        val cfg = Prefs.leer(this)
        val input = EditText(this).apply {
            setText(cfg.nombre); hint = "Ej: Caja Zona 3"
            setSingleLine(); setSelection(text.length)
        }
        val cont = android.widget.FrameLayout(this).apply { setPadding(dp(20), dp(8), dp(20), 0) }
        cont.addView(input)
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Nombre del equipo")
            .setMessage("Así lo identificás al toque en el panel MOS.")
            .setView(cont)
            .setPositiveButton("Guardar") { _, _ ->
                val nom = input.text.toString().trim()
                if (nom.isNotEmpty() && nom != cfg.nombre) renombrar(nom)
            }
            .setNegativeButton("Ahora no", null)
            .show()
    }

    /** Renombra el equipo probando su identidad con su PROPIO secreto (no la clave master). */
    private fun renombrar(nombre: String) {
        val cfg = Prefs.leer(this)
        if (cfg.secreto.isBlank()) { Toast.makeText(this, "Conectá el equipo primero", Toast.LENGTH_SHORT).show(); return }
        Toast.makeText(this, "Guardando…", Toast.LENGTH_SHORT).show()
        thread {
            var con: HttpURLConnection? = null
            var okNom = false
            try {
                con = (URL(Backend.URL.trimEnd('/') + "/rest/v1/rpc/yape_guard_renombrar").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"; connectTimeout = 12000; readTimeout = 15000; doOutput = true
                    setRequestProperty("apikey", Backend.ANON)
                    setRequestProperty("Authorization", "Bearer " + Backend.ANON)
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Content-Profile", "mos")
                }
                val p = JSONObject().put("secreto", cfg.secreto).put("nombre", nombre)
                con.outputStream.use { it.write(JSONObject().put("p", p).toString().toByteArray(Charsets.UTF_8)) }
                if (con.responseCode in 200..299) {
                    val r = JSONObject(con.inputStream.bufferedReader().use { it.readText() })
                    if (r.optBoolean("ok", false)) {
                        Prefs.guardar(this, Config(cfg.secreto, nombre, cfg.zona)); okNom = true
                    }
                }
            } catch (_: Throwable) {
            } finally { try { con?.disconnect() } catch (_: Throwable) {} }
            runOnUiThread {
                Toast.makeText(this, if (okNom) "✅ Nombre guardado" else "No se pudo guardar", Toast.LENGTH_SHORT).show()
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
