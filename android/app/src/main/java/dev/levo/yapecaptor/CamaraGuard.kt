package dev.levo.yapecaptor

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * [MosGuard · fase 2] CÁMARA de resguardo — Camera2 SIN vista previa, en un foreground service.
 *
 * Para qué: si el equipo se pierde, el dueño (desde MOS) pide una foto o "en vivo" (cuadros cada ~2s).
 * La toma la cámara frontal (quién lo tiene) o la trasera si no hay, sin abrir nada en pantalla, y
 * sube el JPEG a Storage por la Edge guard-media (mismo secreto del equipo). NUNCA toca el micrófono.
 *
 * Solo existe en la edición MosGuard (BuildConfig.ES_GUARD). El YapeCaptor de producción no declara
 * el permiso de cámara ni este servicio.
 *
 * OJO: capturar con la pantalla apagada / la app de fondo depende del fabricante (Android exige un
 * foreground service tipo `camera`, ya declarado). Es lo que hay que probar en un equipo real.
 */
class CamaraGuard : Service() {

    companion object {
        private const val TAG = "YapeCaptor"
        private const val CANAL = "yape_captor"
        private const val NOTIF_ID = 4713
        private const val EXTRA_MODO = "modo"          // "foto" | "live"
        private const val EXTRA_HASTA = "hastaMs"      // fin de la ventana en vivo (epoch ms)
        @Volatile private var trabajando = false

        /** Dispara UNA foto. */
        fun foto(ctx: Context) = arrancar(ctx, "foto", 0L)

        /** Arranca "en vivo" hasta `hastaMs` (epoch en milisegundos). */
        fun vivo(ctx: Context, hastaMs: Long) = arrancar(ctx, "live", hastaMs)

        private fun arrancar(ctx: Context, modo: String, hastaMs: Long) {
            if (!BuildConfig.ES_GUARD) return
            if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return
            try {
                val i = Intent(ctx, CamaraGuard::class.java).putExtra(EXTRA_MODO, modo).putExtra(EXTRA_HASTA, hastaMs)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (e: Throwable) { Log.w(TAG, "cámara: no pude arrancar ${e.message}") }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        enPrimerPlano()
        val modo = intent?.getStringExtra(EXTRA_MODO) ?: "foto"
        val hasta = intent?.getLongExtra(EXTRA_HASTA, 0L) ?: 0L
        if (!trabajando) {
            trabajando = true
            thread(name = "guard-cam", isDaemon = true) {
                try {
                    if (modo == "live") {
                        while (System.currentTimeMillis() < hasta && BuildConfig.ES_GUARD) {
                            capturarYSubir("frame")
                            try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
                        }
                    } else {
                        capturarYSubir("foto")
                    }
                } finally { trabajando = false; detener() }
            }
        }
        return START_NOT_STICKY
    }

    private fun enPrimerPlano() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(CANAL, "Captura de Yapes", NotificationManager.IMPORTANCE_MIN))
        }
        val n = Notification.Builder(this, CANAL)
            .setContentTitle("MosGuard").setContentText("Resguardo del equipo")
            .setSmallIcon(android.R.drawable.ic_menu_camera).setOngoing(true).build()
        try {
            if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIF_ID, n, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
            else startForeground(NOTIF_ID, n)
        } catch (e: Throwable) { Log.e(TAG, "startForeground cam", e) }
    }

    private fun detener() { try { stopForeground(true) } catch (_: Throwable) {}; stopSelf() }

    /** Toma UN JPEG con Camera2 (sin preview) y lo sube. Bloqueante; corre en el hilo guard-cam. */
    private fun capturarYSubir(tipo: String) {
        val cfg = Prefs.leer(this); if (!cfg.completa()) return
        val jpg = try { capturarJpeg() } catch (e: Throwable) { Log.w(TAG, "captura: ${e.message}"); null } ?: return
        subir(cfg.secreto, jpg, tipo)
    }

    private fun capturarJpeg(): ByteArray? {
        val cm = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val idCam = elegirCamara(cm) ?: return null
        val hilo = HandlerThread("guard-cam2").apply { start() }
        val h = Handler(hilo.looper)
        var resultado: ByteArray? = null
        val lock = Object()
        var listo = false
        val lector = ImageReader.newInstance(1280, 960, ImageFormat.JPEG, 1)
        var cam: CameraDevice? = null
        try {
            lector.setOnImageAvailableListener({ r ->
                val img = try { r.acquireLatestImage() } catch (_: Throwable) { null }
                if (img != null) {
                    try { val buf = img.planes[0].buffer; val b = ByteArray(buf.remaining()); buf.get(b); resultado = b } catch (_: Throwable) {}
                    try { img.close() } catch (_: Throwable) {}
                }
                synchronized(lock) { listo = true; lock.notifyAll() }
            }, h)
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return null
            cm.openCamera(idCam, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    cam = device
                    try {
                        val req = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                        req.addTarget(lector.surface)
                        req.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                        req.set(CaptureRequest.JPEG_ORIENTATION, 0)
                        device.createCaptureSession(listOf(lector.surface), object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                try { session.capture(req.build(), null, h) } catch (_: Throwable) { synchronized(lock) { listo = true; lock.notifyAll() } }
                            }
                            override fun onConfigureFailed(session: CameraCaptureSession) { synchronized(lock) { listo = true; lock.notifyAll() } }
                        }, h)
                    } catch (_: Throwable) { synchronized(lock) { listo = true; lock.notifyAll() } }
                }
                override fun onDisconnected(device: CameraDevice) { device.close(); synchronized(lock) { listo = true; lock.notifyAll() } }
                override fun onError(device: CameraDevice, error: Int) { device.close(); synchronized(lock) { listo = true; lock.notifyAll() } }
            }, h)
            synchronized(lock) { if (!listo) try { lock.wait(8000) } catch (_: InterruptedException) {} }
        } finally {
            try { cam?.close() } catch (_: Throwable) {}
            try { lector.close() } catch (_: Throwable) {}
            try { hilo.quitSafely() } catch (_: Throwable) {}
        }
        return resultado
    }

    /** Cámara frontal (quién lo tiene) si existe; si no, la primera disponible. */
    private fun elegirCamara(cm: CameraManager): String? {
        return try {
            val ids = cm.cameraIdList
            var frontal: String? = null
            for (id in ids) {
                val f = cm.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
                if (f == CameraCharacteristics.LENS_FACING_FRONT) { frontal = id; break }
            }
            frontal ?: ids.firstOrNull()
        } catch (_: Throwable) { null }
    }

    private fun subir(secreto: String, jpg: ByteArray, tipo: String) {
        var con: HttpURLConnection? = null
        try {
            val b64 = Base64.encodeToString(jpg, Base64.NO_WRAP)
            con = (URL(Backend.URL.trimEnd('/') + "/functions/v1/guard-media").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"; connectTimeout = 15000; readTimeout = 30000; doOutput = true
                setRequestProperty("apikey", Backend.ANON)
                setRequestProperty("Authorization", "Bearer " + Backend.ANON)
                setRequestProperty("Content-Type", "application/json")
            }
            val body = JSONObject().put("secreto", secreto).put("tipo", tipo).put("jpgB64", b64)
            con.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            con.responseCode
        } catch (e: Throwable) { Log.w(TAG, "subir foto: ${e.message}") }
        finally { try { con?.disconnect() } catch (_: Throwable) {} }
    }
}
