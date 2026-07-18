// ============================================================
// ProyectoMOS — Audio.gs  ·  [CERO-GAS 2026-07-18] SUBSISTEMA MIGRADO A SUPABASE — ARCHIVO VACIADO
// ============================================================
// QUÉ ES: módulo de MONITOREO DE SEGURIDAD del local (audio) sobre EQUIPOS PROPIEDAD DE LA EMPRESA y APROBADOS
// por la empresa (mismo UUID que controla el ingreso a la app), DENTRO del local. Complemento liviano del CCTV
// (que tiene hosting propio + streaming); acá va en FRAGMENTOS por los límites de Supabase. El push "silencioso"
// es UX (no marear al operador con modales), NO ocultamiento. "espía" = codename interno legacy, NO vigilancia
// encubierta de personas.
//
// El monitoreo de audio ya NO usa GAS / Google Sheets / Google Drive. Nueva arquitectura:
//   · Ciclo de sesión → RPCs mos.espia_audio_* (SQL 508): iniciar/detener/estado/sesiones_listar/chunks/purgar.
//   · Chunks de audio → Edge `espia-chunk` → Storage `espia` + mos.espia_chunks (SQL 413), con URL pública.
//   · Push audio_start/stop → Edge `push` (data-only), desde el controlador MOS (js/api.js _pushComandoDeviceMOS).
//   · Controlador (MOS) → intercepts en js/api.js: iniciar/detener/getEstadoAudio/getSesionesAudio/
//     getChunksAudioSesion/getChunkAudioContent (este último baja la URL pública de Storage → base64).
//   · Device (WH/ME) → graban (MediaRecorder) + suben chunks por Edge; WH cierra su sesión por RPC
//     (API.espiaAudioDetener → mos.espia_audio_detener); ME confía en la expiración server-side.
//
// Las hojas AUDIO_SESIONES / AUDIO_CHUNKS y la carpeta Drive MOS_AUDIO quedaron ORFANADAS (archivo histórico).
// Funciones ELIMINADAS: iniciarEscuchaAudio, detenerEscuchaAudio, subirChunkAudio, getSesionesAudio,
//   getChunksAudioSesion, getChunkAudioContent, getEstadoAudio, limpiarAudioViejo, _pushComandoDispositivo,
//   _garantizarHojasAudio, _getAudioRootFolder + constantes AUDIO_*. Sus router cases se removieron de Code.gs.
// ============================================================
