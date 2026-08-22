package dev.levo.yapecaptor

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.webrtc.*
import org.webrtc.audio.JavaAudioDeviceModule
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * [MosGuard · test emulador CI] Reproduce el escenario del espía nativo SIN depender del celular del dueño
 * (que se dormía). Arma un RTCPeerConnection con la MISMA config que EspiaNativo, fija la descripción local
 * y verifica que:
 *   1) setLocalDescription COMPLETA (en el celular real quedaba en "?" → colgado),
 *   2) el WebRTC nativo JUNTA candidatos ICE (en el celular real era 0).
 * Si esto pasa en el emulador, el código/lib están bien y el problema es específico del equipo (Doze/red
 * de Android 16). Si falla acá, es un bug de código y lo arreglo iterando en el CI, sin el celular.
 */
@RunWith(AndroidJUnit4::class)
class EspiaIceTest {

    @Test
    fun juntaCandidatosICE() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(ctx).createInitializationOptions())
        val egl = EglBase.create()
        val adm = JavaAudioDeviceModule.builder(ctx).createAudioDeviceModule()
        val factory = PeerConnectionFactory.builder()
            .setAudioDeviceModule(adm)
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl.eglBaseContext))
            .createPeerConnectionFactory()

        val ice = listOf(PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer())
        val rtc = PeerConnection.RTCConfiguration(ice).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }

        val candCount = AtomicInteger(0)
        val primerCand = CountDownLatch(1)
        val gathState = StringBuilder()

        val pc = factory.createPeerConnection(rtc, object : PeerConnection.Observer {
            override fun onIceCandidate(c: IceCandidate?) { candCount.incrementAndGet(); primerCand.countDown() }
            override fun onIceGatheringChange(s: PeerConnection.IceGatheringState?) { gathState.append(s?.name).append(",") }
            override fun onSignalingChange(s: PeerConnection.SignalingState?) {}
            override fun onIceConnectionChange(s: PeerConnection.IceConnectionState?) {}
            override fun onIceConnectionReceivingChange(b: Boolean) {}
            override fun onIceCandidatesRemoved(c: Array<out IceCandidate>?) {}
            override fun onAddStream(s: MediaStream?) {}
            override fun onRemoveStream(s: MediaStream?) {}
            override fun onDataChannel(d: DataChannel?) {}
            override fun onRenegotiationNeeded() {}
            override fun onAddTrack(r: RtpReceiver?, s: Array<out MediaStream>?) {}
        })!!

        // una pista de audio → hay una m-line que gatilla el ICE (como en EspiaNativo)
        val audioTrack = factory.createAudioTrack("t_a0", factory.createAudioSource(MediaConstraints()))
        pc.addTrack(audioTrack, listOf("t_stream"))

        val localOk = CountDownLatch(1)
        val localErr = StringBuilder()
        pc.createOffer(object : SdpObserver {
            override fun onCreateSuccess(desc: SessionDescription) {
                pc.setLocalDescription(object : SdpObserver {
                    override fun onSetSuccess() { localOk.countDown() }
                    override fun onSetFailure(e: String?) { localErr.append(e); localOk.countDown() }
                    override fun onCreateSuccess(d: SessionDescription?) {}
                    override fun onCreateFailure(e: String?) {}
                }, desc)
            }
            override fun onCreateFailure(e: String?) { localErr.append("createOffer:").append(e); localOk.countDown() }
            override fun onSetSuccess() {}
            override fun onSetFailure(e: String?) {}
        }, MediaConstraints())

        val setOk = localOk.await(10, TimeUnit.SECONDS)
        val gotCand = primerCand.await(20, TimeUnit.SECONDS)

        // resultado en el mensaje del assert (queda en el log del CI)
        val resumen = "setLocalDescription=${if (setOk) "OK" else "TIMEOUT"} err='${localErr}' · gathering=[$gathState] · candidatos=${candCount.get()}"
        assertTrue("NO completó setLocalDescription · $resumen", setOk && localErr.isEmpty())
        assertTrue("NO juntó candidatos ICE · $resumen", gotCand && candCount.get() > 0)
    }
}
