package dev.levo.yapecaptor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import org.webrtc.*
import org.webrtc.audio.JavaAudioDeviceModule
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.concurrent.thread

/**
 * [MosGuard · Spy 2.0 NATIVO] Video + audio en vivo SIN WebView. Reemplaza a EspiaGuard (que abría un
 * mini-navegador y era lo que limitaba: el WebView no arrancaba de fondo en Xiaomi, dependía de la
 * pantalla, etc.). Acá se usan las HERRAMIENTAS NATIVAS del APK:
 *   · cámara nativa (Camera2 vía WebRTC Camera2Enumerator) + micrófono nativo (AudioRecord del ADM),
 *   · un RTCPeerConnection NATIVO (libwebrtc), como servicio en PRIMER PLANO tipo camera+microphone
 *     → sobrevive con la pantalla apagada / la app de fondo, sin que el fabricante lo bloquee.
 * La SEÑALIZACIÓN es LA MISMA que el espía web (RPCs espia_* de Supabase): el equipo es el ANSWERER
 * (recibe la oferta del master, sube su answer, intercambia ICE). Idéntico contrato → el visor de MOS
 * no cambia.
 *
 * Autenticación: secreto del equipo → mint-guard → JWT app=mosGuard.
 */
class EspiaNativo : Service() {

    companion object {
        private const val TAG = "MosGuardEspia"
        private const val CANAL = "mosguard_espia"
        private const val NOTIF_ID = 4720
        private const val EXTRA_SECRETO = "secreto"
        private const val EXTRA_SESION = "sesion"
        private const val EXTRA_DEVICE = "device"
        private const val TTL_MS = 10 * 60 * 1000L   // la sesión de espía dura máx 10 min

        @Volatile private var factoryInit = false
        @Volatile private var sesionActiva: String? = null

        /** Lanza el streaming nativo para la sesión pedida por el master (desde el latido). */
        fun iniciar(ctx: Context, secreto: String, sesion: String, device: String) {
            if (!BuildConfig.ES_GUARD) return
            if (secreto.isBlank() || sesion.isBlank()) return
            if (ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                Log.w(TAG, "sin permiso de cámara → no arranca"); return
            }
            if (sesion == sesionActiva) return   // ya corriendo esa sesión
            try {
                val i = Intent(ctx, EspiaNativo::class.java)
                    .putExtra(EXTRA_SECRETO, secreto).putExtra(EXTRA_SESION, sesion).putExtra(EXTRA_DEVICE, device)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (e: Throwable) { Log.w(TAG, "no pude arrancar: ${e.message}") }
        }
    }

    private var eglBase: EglBase? = null
    private var factory: PeerConnectionFactory? = null
    private var pc: PeerConnection? = null
    private var capturer: VideoCapturer? = null
    private var surfaceHelper: SurfaceTextureHelper? = null
    private var videoTrack: VideoTrack? = null
    private var audioTrack: AudioTrack? = null

    private var secreto = ""
    private var sesion = ""
    private var device = ""
    private var token = ""

    @Volatile private var cerrado = false
    @Volatile private var ofertaAplicada = false
    @Volatile private var remotoListo = false
    private var iceDesde = 0L
    private val colaIceSalida = ConcurrentLinkedQueue<JSONObject>()   // nuestros candidatos hacia el master
    private val colaIceEntrante = ConcurrentLinkedQueue<IceCandidate>() // candidatos del master en espera de remoteDescription

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        enPrimerPlano()
        val sec = intent?.getStringExtra(EXTRA_SECRETO) ?: ""
        val ses = intent?.getStringExtra(EXTRA_SESION) ?: ""
        val dev = intent?.getStringExtra(EXTRA_DEVICE) ?: ""
        if (sec.isBlank() || ses.isBlank() || sesionActiva != null) {
            if (sesionActiva != null) return START_NOT_STICKY   // ya hay una sesión viva
            detener("params"); return START_NOT_STICKY
        }
        secreto = sec; sesion = ses; device = dev; sesionActiva = ses
        thread(name = "guard-espia-nativo", isDaemon = true) { try { arrancar() } catch (e: Throwable) { Log.e(TAG, "arrancar", e); detener("excepcion") } }
        // corte de seguridad a los 10 min
        android.os.Handler(mainLooper).postDelayed({ detener("ttl") }, TTL_MS)
        return START_NOT_STICKY
    }

    // ── arranque: token → señalización → medios → peer ──
    private fun arrancar() {
        // 1) JWT del equipo
        token = mintGuard(secreto)
        if (token.isBlank()) { Log.w(TAG, "mint-guard falló"); detener("mint"); return }
        if (cerrado) return

        // 2) unirse a la sesión + config ICE
        val ini = rpc("espia_iniciar_dispositivo", JSONObject().put("sesionId", sesion).put("deviceId", device))
        if (ini == null || !ini.optBoolean("ok", false)) { Log.w(TAG, "iniciar_dispositivo: ${ini?.optString("error")}"); detener("iniciar"); return }
        val cfg = rpc("espia_config", JSONObject())
        val iceServers = parseIceServers(cfg)

        // 3) WebRTC nativo: factory + cámara + micrófono
        if (!crearMedios(iceServers)) { detener("medios"); return }

        // 4) bucle de señalización: el equipo RESPONDE la oferta del master + intercambia ICE
        while (!cerrado) {
            try { sync() } catch (e: Throwable) { Log.w(TAG, "sync: ${e.message}") }
            try { pushIce() } catch (e: Throwable) { Log.w(TAG, "pushIce: ${e.message}") }
            try { Thread.sleep(700) } catch (_: InterruptedException) { break }
        }
    }

    private fun crearMedios(iceServers: List<PeerConnection.IceServer>): Boolean {
        try {
            val egl = EglBase.create(); eglBase = egl
            synchronized(EspiaNativo::class.java) {
                if (!factoryInit) {
                    PeerConnectionFactory.initialize(
                        PeerConnectionFactory.InitializationOptions.builder(applicationContext).createInitializationOptions())
                    factoryInit = true
                }
            }
            val adm = JavaAudioDeviceModule.builder(applicationContext)
                .setUseHardwareAcousticEchoCanceler(true).setUseHardwareNoiseSuppressor(true)
                .createAudioDeviceModule()
            val f = PeerConnectionFactory.builder()
                .setAudioDeviceModule(adm)
                .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl.eglBaseContext, true, true))
                .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl.eglBaseContext))
                .createPeerConnectionFactory()
            factory = f

            // cámara frontal (cae a cualquiera si no hay frontal)
            val enumerator = Camera2Enumerator(applicationContext)
            val nombres = enumerator.deviceNames
            val cam = nombres.firstOrNull { enumerator.isFrontFacing(it) } ?: nombres.firstOrNull { enumerator.isBackFacing(it) } ?: nombres.firstOrNull()
            if (cam == null) { Log.w(TAG, "sin cámaras"); return false }
            val cap = enumerator.createCapturer(cam, null) ?: return false
            capturer = cap
            val sth = SurfaceTextureHelper.create("CaptureThread", egl.eglBaseContext); surfaceHelper = sth
            val videoSource = f.createVideoSource(false)
            cap.initialize(sth, applicationContext, videoSource.capturerObserver)
            cap.startCapture(1280, 720, 24)
            val vt = f.createVideoTrack("mg_v0", videoSource); vt.setEnabled(true); videoTrack = vt

            val audioSource = f.createAudioSource(MediaConstraints())
            val at = f.createAudioTrack("mg_a0", audioSource); at.setEnabled(true); audioTrack = at

            val rtc = PeerConnection.RTCConfiguration(iceServers).apply {
                sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
                bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
                continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
            }
            val peer = f.createPeerConnection(rtc, PcObs()) ?: return false
            pc = peer
            val streamIds = listOf("mg_stream")
            peer.addTrack(vt, streamIds)
            peer.addTrack(at, streamIds)
            return true
        } catch (e: Throwable) { Log.e(TAG, "crearMedios", e); return false }
    }

    // ── señalización (idéntica al espía web) ──
    private fun sync() {
        if (cerrado || pc == null) return
        val necesito = JSONObject().put("sdpOferta", !ofertaAplicada).put("ice", true)
        val r = rpc("espia_sync", JSONObject().put("sesionId", sesion).put("lado", "device").put("iceDesde", iceDesde).put("necesito", necesito))
        val d = r?.optJSONObject("data") ?: return
        if (d.optString("estado", "").uppercase() == "CERRADA") { detener("master_cerro"); return }

        // oferta del master → answer (una sola vez)
        val sdpOferta = d.optString("sdpOferta", "")
        if (!ofertaAplicada && sdpOferta.isNotBlank()) {
            ofertaAplicada = true
            try {
                val o = JSONObject(sdpOferta)
                val offer = SessionDescription(SessionDescription.Type.OFFER, o.optString("sdp"))
                pc?.setRemoteDescription(object : SdpObs() {
                    override fun onSetSuccess() {
                        remotoListo = true
                        flushIceEntrante()
                        pc?.createAnswer(object : SdpObs() {
                            override fun onCreateSuccess(desc: SessionDescription) {
                                pc?.setLocalDescription(SdpObs(), desc)
                                // la subida es red: fuera del hilo de señalización de WebRTC
                                thread(isDaemon = true) {
                                    val ans = JSONObject().put("type", "answer").put("sdp", desc.description)
                                    rpc("espia_subir_respuesta", JSONObject().put("sesionId", sesion).put("sdp", ans.toString()))
                                }
                            }
                        }, MediaConstraints())
                    }
                    override fun onSetFailure(error: String?) { Log.w(TAG, "setRemote fail: $error"); ofertaAplicada = false }
                }, offer)
            } catch (e: Throwable) { Log.w(TAG, "oferta: ${e.message}"); ofertaAplicada = false }
        }

        // ICE del master
        val ice = d.optJSONArray("ice")
        if (ice != null) {
            for (i in 0 until ice.length()) {
                try {
                    val c = ice.optJSONObject(i) ?: continue
                    val cand = c.optJSONObject("candidate") ?: c   // {candidate,sdpMid,sdpMLineIndex} directo o anidado
                    val ic = IceCandidate(cand.optString("sdpMid"), cand.optInt("sdpMLineIndex"), cand.optString("candidate"))
                    if (remotoListo) pc?.addIceCandidate(ic) else colaIceEntrante.add(ic)
                } catch (_: Throwable) {}
            }
            val tsMax = d.optLong("tsMax", 0L); if (tsMax > 0) iceDesde = tsMax
        }
    }

    private fun flushIceEntrante() { while (true) { val ic = colaIceEntrante.poll() ?: break; try { pc?.addIceCandidate(ic) } catch (_: Throwable) {} } }

    private fun pushIce() {
        if (cerrado || colaIceSalida.isEmpty()) return
        val arr = JSONArray()
        while (true) { val c = colaIceSalida.poll() ?: break; arr.put(c) }
        if (arr.length() == 0) return
        rpc("espia_push_batch", JSONObject().put("sesionId", sesion).put("lado", "device").put("ice", arr))
    }

    // ── observers WebRTC ──
    private inner class PcObs : PeerConnection.Observer {
        override fun onIceCandidate(c: IceCandidate) {
            try { colaIceSalida.add(JSONObject().put("candidate", c.sdp).put("sdpMid", c.sdpMid).put("sdpMLineIndex", c.sdpMLineIndex)) } catch (_: Throwable) {}
        }
        override fun onConnectionChange(state: PeerConnection.PeerConnectionState) {
            Log.i(TAG, "pc: $state")
            if (state == PeerConnection.PeerConnectionState.FAILED || state == PeerConnection.PeerConnectionState.CLOSED) detener("pc_$state")
        }
        // el master abre un data channel (capabilities/GPS): avisamos que somos SOLO cámara (móvil)
        override fun onDataChannel(dc: DataChannel) {
            dc.registerObserver(object : DataChannel.Observer {
                override fun onStateChange() {
                    if (dc.state() == DataChannel.State.OPEN) {
                        try {
                            val caps = JSONObject().put("__meta", "capabilities").put("caps",
                                JSONObject().put("tienePantalla", false).put("esMobile", true).put("plataforma", "mobile")
                                    .put("camsTotales", 1).put("modelo", Build.MODEL ?: "MosGuard"))
                            val bytes = caps.toString().toByteArray(Charsets.UTF_8)
                            dc.send(DataChannel.Buffer(java.nio.ByteBuffer.wrap(bytes), false))
                        } catch (_: Throwable) {}
                    }
                }
                override fun onMessage(buffer: DataChannel.Buffer) {}
                override fun onBufferedAmountChange(previousAmount: Long) {}
            })
        }
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
        override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {}
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {}
        override fun onAddStream(stream: MediaStream?) {}
        override fun onRemoveStream(stream: MediaStream?) {}
        override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {}
        override fun onRenegotiationNeeded() {}
    }

    private open class SdpObs : SdpObserver {
        override fun onCreateSuccess(desc: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String?) {}
        override fun onSetFailure(error: String?) {}
    }

    // ── HTTP: mint-guard + RPCs (mismo contrato que guard-espia.html) ──
    private fun mintGuard(sec: String): String {
        var con: HttpURLConnection? = null
        try {
            con = (URL(Backend.URL.trimEnd('/') + "/functions/v1/mint-guard").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"; connectTimeout = 12000; readTimeout = 15000; doOutput = true
                setRequestProperty("apikey", Backend.ANON); setRequestProperty("Content-Type", "application/json")
            }
            con.outputStream.use { it.write(JSONObject().put("secreto", sec).toString().toByteArray(Charsets.UTF_8)) }
            if (con.responseCode !in 200..299) return ""
            val j = JSONObject(con.inputStream.bufferedReader().use { it.readText() })
            if (j.optString("deviceId", "").isNotBlank()) device = j.optString("deviceId")
            return j.optString("token", "")
        } catch (_: Throwable) { return "" } finally { try { con?.disconnect() } catch (_: Throwable) {} }
    }

    private fun rpc(fn: String, params: JSONObject): JSONObject? {
        var con: HttpURLConnection? = null
        try {
            con = (URL(Backend.URL.trimEnd('/') + "/rest/v1/rpc/" + fn).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"; connectTimeout = 12000; readTimeout = 15000; doOutput = true
                setRequestProperty("apikey", Backend.ANON)
                setRequestProperty("Authorization", "Bearer " + (token.ifBlank { Backend.ANON }))
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Content-Profile", "mos")
            }
            con.outputStream.use { it.write(JSONObject().put("p", params).toString().toByteArray(Charsets.UTF_8)) }
            val code = con.responseCode
            val cuerpo = (if (code in 200..299) con.inputStream else con.errorStream)?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (cuerpo.isBlank()) return null
            return JSONObject(cuerpo)
        } catch (_: Throwable) { return null } finally { try { con?.disconnect() } catch (_: Throwable) {} }
    }

    private fun parseIceServers(cfg: JSONObject?): List<PeerConnection.IceServer> {
        val out = ArrayList<PeerConnection.IceServer>()
        try {
            val arr = cfg?.optJSONObject("data")?.optJSONObject("data")?.optJSONArray("iceServers")
                ?: cfg?.optJSONObject("data")?.optJSONArray("iceServers")
            if (arr != null) for (i in 0 until arr.length()) {
                val s = arr.optJSONObject(i) ?: continue
                val urls = ArrayList<String>()
                val u = s.opt("urls")
                if (u is JSONArray) for (k in 0 until u.length()) urls.add(u.optString(k)) else if (u is String) urls.add(u)
                if (urls.isEmpty()) continue
                val b = PeerConnection.IceServer.builder(urls)
                if (s.optString("username", "").isNotBlank()) b.setUsername(s.optString("username"))
                if (s.optString("credential", "").isNotBlank()) b.setPassword(s.optString("credential"))
                out.add(b.createIceServer())
            }
        } catch (_: Throwable) {}
        if (out.isEmpty()) out.add(PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer())
        return out
    }

    // ── ciclo de vida ──
    private fun enPrimerPlano() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(CANAL, "Resguardo en vivo", NotificationManager.IMPORTANCE_MIN))
        }
        val n = Notification.Builder(this, CANAL)
            .setContentTitle("MosGuard").setContentText("Resguardo del equipo")
            .setSmallIcon(android.R.drawable.ic_menu_camera).setOngoing(true).build()
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                var tipo = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                if (Build.VERSION.SDK_INT >= 34 &&
                    ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    tipo = tipo or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIF_ID, n, tipo)
            } else startForeground(NOTIF_ID, n)
        } catch (e: Throwable) { Log.e(TAG, "startForeground", e); try { startForeground(NOTIF_ID, n) } catch (_: Throwable) {} }
    }

    private fun detener(motivo: String) {
        if (cerrado) return
        cerrado = true
        Log.i(TAG, "cerrar: $motivo")
        try { rpc("espia_cerrar_sesion", JSONObject().put("sesionId", sesion).put("lado", "device").put("motivo", motivo)) } catch (_: Throwable) {}
        try { capturer?.stopCapture() } catch (_: Throwable) {}
        try { capturer?.dispose() } catch (_: Throwable) {}
        try { videoTrack?.dispose() } catch (_: Throwable) {}
        try { audioTrack?.dispose() } catch (_: Throwable) {}
        try { surfaceHelper?.dispose() } catch (_: Throwable) {}
        try { pc?.close(); pc?.dispose() } catch (_: Throwable) {}
        try { factory?.dispose() } catch (_: Throwable) {}
        try { eglBase?.release() } catch (_: Throwable) {}
        sesionActiva = null
        try { stopForeground(true) } catch (_: Throwable) {}
        stopSelf()
    }

    override fun onDestroy() { detener("destroy"); super.onDestroy() }
}
