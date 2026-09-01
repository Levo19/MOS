// ═══════════════════════════════════════════════════════════════════════════
// Edge `buzon-ia` — cerebro del Buzón Directo (SQL 1009) · 01-sep-2026
// Ops (POST {op,...}):
//   sugerir      {idTicket}                 → borrador de respuesta para el Master (RAG manual + sus QA previas)
//   indexar_qa   {idTicket}                 → indexa la ÚLTIMA respuesta del master del ticket (aprende)
//   indexar_docs {chunks:[{fuente,seccion,contenido}]} → embebe e indexa el manual (≤40 por llamada)
// AUTH: verify_jwt=true (firma) + claim app='MOS' (panel del Master) o role='service_role' (indexador local).
// Embeddings: gemini text-embedding-004 (768 dims, batch), fallback gemini-embedding-001@768.
// Generación: geminiMessages (adaptador compartido) con gemini-2.5-flash. Contabilidad: ia_registrar_uso.
// ═══════════════════════════════════════════════════════════════════════════
import { geminiMessages, GEMINI_FLASH } from '../_shared/gemini.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
function jwtClaims(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1];
    if (!part) return null;
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return JSON.parse(atob(b64));
  } catch { return null; }
}
function _iaLog(rec: Record<string, unknown>): void {
  try {
    const _u = Deno.env.get('SUPABASE_URL'); const _k = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!_u || !_k) return;
    fetch(`${_u}/rest/v1/rpc/ia_registrar_uso`, {
      method: 'POST',
      headers: { apikey: _k, Authorization: 'Bearer ' + _k, 'Content-Type': 'application/json', 'Content-Profile': 'mos' },
      body: JSON.stringify({ p: rec }),
    }).catch(() => {});
  } catch { /* nunca rompe */ }
}

// ── acceso service a PostgREST (RPC esquema mos / tablas) ───────────────────
function svcHeaders(): Record<string, string> {
  const k = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  return { apikey: k, Authorization: 'Bearer ' + k, 'Content-Type': 'application/json',
           'Content-Profile': 'mos', 'Accept-Profile': 'mos' };
}
async function rpcMos(fn: string, p: unknown): Promise<Record<string, unknown>> {
  const u = Deno.env.get('SUPABASE_URL');
  const r = await fetch(`${u}/rest/v1/rpc/${fn}`, { method: 'POST', headers: svcHeaders(), body: JSON.stringify({ p }) });
  const d = await r.json().catch(() => null);
  if (!r.ok) throw new Error(fn + ' HTTP ' + r.status + ': ' + JSON.stringify(d).slice(0, 200));
  return d as Record<string, unknown>;
}
async function tabla(path: string): Promise<Record<string, unknown>[]> {
  const u = Deno.env.get('SUPABASE_URL');
  const r = await fetch(`${u}/rest/v1/${path}`, { headers: svcHeaders() });
  const d = await r.json().catch(() => null);
  if (!r.ok || !Array.isArray(d)) throw new Error('tabla ' + path.split('?')[0] + ' HTTP ' + r.status);
  return d as Record<string, unknown>[];
}

// ── embeddings Gemini (batch), 768 dims ─────────────────────────────────────
const EMB_PRIMARIO = 'text-embedding-004';
const EMB_ALTERNO  = 'gemini-embedding-001';   // exige outputDimensionality:768
async function embed(key: string, textos: string[], taskType: string): Promise<number[][]> {
  const intento = async (modelo: string): Promise<{ ok: boolean; status: number; vecs?: number[][]; err?: string }> => {
    const body = { requests: textos.map((t) => ({
      model: 'models/' + modelo,
      content: { parts: [{ text: String(t).slice(0, 8000) }] },
      taskType,
      ...(modelo === EMB_ALTERNO ? { outputDimensionality: 768 } : {}),
    })) };
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modelo}:batchEmbedContents`, {
      method: 'POST', headers: { 'x-goog-api-key': key, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    const d = await r.json().catch(() => ({}));
    if (!r.ok) return { ok: false, status: r.status, err: String((d as Record<string, { message?: string }>)?.error?.message || r.status).slice(0, 200) };
    const vecs = ((d as Record<string, unknown>).embeddings as { values: number[] }[] | undefined)?.map((e) => e.values);
    if (!vecs || vecs.length !== textos.length) return { ok: false, status: 500, err: 'embeddings incompletos' };
    return { ok: true, status: 200, vecs };
  };
  let r = await intento(EMB_PRIMARIO);
  if (!r.ok && (r.status === 404 || r.status === 429)) r = await intento(EMB_ALTERNO);
  if (!r.ok) throw new Error('embed: ' + r.err);
  return r.vecs!;
}
const vecStr = (v: number[]) => '[' + v.map((x) => Number(x.toFixed(6))).join(',') + ']';

// ── armar la "pregunta" de un ticket (título + campos + textos del admin) ───
type Msg = { id?: number; autor_tipo?: string; tipo?: string; texto?: string };
function preguntaDe(ticket: Record<string, unknown>, mensajes: Msg[]): string {
  const campos = (ticket.campos || {}) as Record<string, unknown>;
  const partes = [String(ticket.titulo || '')];
  for (const k of ['app', 'modulo', 'tema', 'tipo', 'zona']) if (campos[k]) partes.push(k + ': ' + String(campos[k]));
  const admin = mensajes.filter((m) => (m.autor_tipo || m.tipo) === 'admin' && m.texto).slice(-3).map((m) => String(m.texto));
  return (partes.join(' · ') + '\n' + admin.join('\n')).trim().slice(0, 4000);
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'método no permitido' }, 405);
  try {
    const auth = req.headers.get('Authorization') || '';
    const claims = jwtClaims(auth.replace(/^Bearer\s+/i, '').trim());
    const esMOS = !!claims && String(claims.app) === 'MOS';
    const esSvc = !!claims && String(claims.role) === 'service_role';
    if (!esMOS && !esSvc) return json({ ok: false, error: 'no autorizado (claim app=MOS o service)' }, 401);

    const gkey = Deno.env.get('GEMINI_API_KEY');
    if (!gkey) return json({ ok: false, error: 'GEMINI_API_KEY no configurada' }, 500);
    const body = await req.json().catch(() => ({}));
    const op = String(body.op || '');
    const t0 = Date.now();

    // ── indexar_docs: corpus del manual (service u MOS) ─────────────────────
    if (op === 'indexar_docs') {
      const chunks = Array.isArray(body.chunks) ? body.chunks.slice(0, 40) : [];
      if (!chunks.length) return json({ ok: false, error: 'chunks[] vacío' }, 400);
      const vecs = await embed(gkey, chunks.map((c: Record<string, unknown>) => String(c.seccion || '') + '\n' + String(c.contenido || '')), 'RETRIEVAL_DOCUMENT');
      let n = 0;
      for (let i = 0; i < chunks.length; i++) {
        await rpcMos('buzon_ia_upsert_doc', { fuente: chunks[i].fuente, seccion: chunks[i].seccion,
          contenido: chunks[i].contenido, emb: vecStr(vecs[i]) });
        n++;
      }
      return json({ ok: true, indexados: n });
    }

    // ── indexar_qa: aprender de la última respuesta del master del ticket ───
    if (op === 'indexar_qa') {
      const idT = parseInt(String(body.idTicket)) || 0;
      if (!idT) return json({ ok: false, error: 'idTicket requerido' }, 400);
      const tk = await tabla(`buzon_tickets?id=eq.${idT}&select=id,titulo,campos`);
      const ms = await tabla(`buzon_mensajes?id_ticket=eq.${idT}&select=id,autor_tipo,texto,media&order=id.asc`);
      if (!tk.length) return json({ ok: false, error: 'ticket no existe' }, 404);
      const masters = ms.filter((m) => m.autor_tipo === 'master' &&
        (String(m.texto || '').trim().length > 2 || (Array.isArray(m.media) && m.media.length)));
      if (!masters.length) return json({ ok: true, indexado: false, motivo: 'sin respuesta del master' });
      const ult = masters[masters.length - 1] as Record<string, unknown>;
      // [pedido del dueño] Si el Master respondió con CAPTURAS, la IA las LEE (visión) y guarda su
      // descripción junto a la respuesta → el contexto futuro sabe qué pantalla/recorte envió.
      let respuesta = String(ult.texto || '');
      const medias = (Array.isArray(ult.media) ? ult.media : []) as Record<string, unknown>[];
      let capDescr = 0;
      for (const md of medias.slice(0, 2)) {
        if (String(md.tipo) === 'video' || !md.url) continue;
        try {
          const ir = await fetch(String(md.url));
          if (!ir.ok) continue;
          const buf = new Uint8Array(await ir.arrayBuffer());
          if (buf.byteLength > 2_500_000) continue;
          let bin = ''; const CH = 32768;
          for (let i = 0; i < buf.length; i += CH) bin += String.fromCharCode(...buf.subarray(i, i + CH));
          const b64 = btoa(bin);
          const gv = await geminiMessages({ key: gkey, model: GEMINI_FLASH, max_tokens: 200, pensar: 0, timeoutMs: 45000,
            system: 'Describe en 1-2 frases, en español, qué muestra esta captura del sistema MOS (pantalla, botones, datos clave). Solo la descripción.',
            messages: [{ role: 'user', content: [
              { type: 'image', source: { type: 'base64', media_type: String(ir.headers.get('content-type') || 'image/jpeg'), data: b64 } },
              { type: 'text', text: String(md.cap || 'captura adjunta') },
            ] as unknown as string }] });
          const desc = gv.ok && gv.data ? String(((gv.data.content as { text?: string }[])[0] || {}).text || '').trim() : '';
          if (desc) { respuesta += '\n[El Master adjuntó una captura: ' + desc.slice(0, 300) + ']'; capDescr++; }
        } catch { /* una imagen ilegible no rompe el indexado */ }
      }
      const pregunta = preguntaDe(tk[0], ms as Msg[]);
      const [v] = await embed(gkey, [pregunta], 'RETRIEVAL_DOCUMENT');
      await rpcMos('buzon_ia_guardar_qa', { idMensaje: ult.id, idTicket: idT, pregunta, respuesta, emb: vecStr(v) });
      return json({ ok: true, indexado: true, idMensaje: ult.id, capturasLeidas: capDescr });
    }

    // ── sugerir: borrador para el Master ────────────────────────────────────
    if (op === 'sugerir') {
      const idT = parseInt(String(body.idTicket)) || 0;
      if (!idT) return json({ ok: false, error: 'idTicket requerido' }, 400);
      const tk = await tabla(`buzon_tickets?id=eq.${idT}&select=id,titulo,categoria,campos,autor_nombre,autor_zona`);
      const ms = await tabla(`buzon_mensajes?id_ticket=eq.${idT}&select=id,autor_tipo,texto&order=id.asc`);
      if (!tk.length) return json({ ok: false, error: 'ticket no existe' }, 404);
      const consulta = preguntaDe(tk[0], ms as Msg[]);
      const [qv] = await embed(gkey, [consulta], 'RETRIEVAL_QUERY');
      const ctx = await rpcMos('buzon_ia_buscar', { emb: vecStr(qv), kDocs: 4, kQa: 3 });
      const docs = (ctx.docs || []) as Record<string, unknown>[];
      const qa = (ctx.qa || []) as Record<string, unknown>[];
      const bloques: string[] = [];
      if (qa.length) bloques.push('ASÍ RESPONDIÓ EL MASTER ANTES A PREGUNTAS PARECIDAS (imita su estilo y criterio):\n' +
        qa.map((x, i) => `${i + 1}. Pregunta: ${x.pregunta}\n   Respuesta del Master: ${x.respuesta}`).join('\n'));
      if (docs.length) bloques.push('MANUAL OPERATIVO (fragmentos relevantes):\n' +
        docs.map((d) => `— [${d.fuente} · ${d.seccion}]\n${d.contenido}`).join('\n\n'));
      const system =
        'Eres el asistente del MASTER (dueño) del ecosistema MOS (panel MOS, punto de venta MosExpress/ME y almacén WarehouseMos/WH). ' +
        'Un administrador le escribió por el Buzón Directo y tú redactas el BORRADOR de respuesta que el Master editará antes de enviar. ' +
        'Reglas: responde EN ESPAÑOL, directo y práctico, en 2-6 oraciones, con los pasos concretos (pantalla → botón) cuando apliquen. ' +
        'Usa SOLO la información del contexto; si el contexto no alcanza para responder con seguridad, dilo claramente en una línea y sugiere qué preguntar. ' +
        'No inventes pantallas ni botones. No saludes con formalidades largas; tono cercano como jefe directo.';
      const user = 'TICKET de ' + String(tk[0].autor_nombre || 'admin') + (tk[0].autor_zona ? ' (' + tk[0].autor_zona + ')' : '') +
        ' · categoría ' + String(tk[0].categoria || '') + ':\n' + consulta +
        (bloques.length ? '\n\n=== CONTEXTO ===\n' + bloques.join('\n\n') : '\n\n(No hay contexto indexado todavía.)');
      const g = await geminiMessages({ key: gkey, model: GEMINI_FLASH, system,
        messages: [{ role: 'user', content: user }], max_tokens: 700, temperature: 0.4, pensar: 0, timeoutMs: 60000 });
      const texto = g.ok && g.data ? String(((g.data.content as { text?: string }[])[0] || {}).text || '') : '';
      _iaLog({ app: 'MOS', funcion: 'buzon-ia', modelo: String(g.data?.model || GEMINI_FLASH), ok: g.ok,
               ms: Date.now() - t0, usage: g.data?.usage || {}, error: g.ok ? undefined : String(g.error || '').slice(0, 200),
               meta: { proveedor: 'gemini', idTicket: idT, docs: docs.length, qa: qa.length } });
      if (!g.ok || !texto) return json({ ok: false, error: String(g.error || 'IA sin respuesta') }, 502);
      return json({ ok: true, borrador: texto,
        fuentes: docs.map((d) => ({ fuente: d.fuente, seccion: d.seccion, sim: d.sim })),
        qaUsadas: qa.length });
    }

    return json({ ok: false, error: 'op inválida (sugerir | indexar_qa | indexar_docs)' }, 400);
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e).slice(0, 300) }, 500);
  }
});
