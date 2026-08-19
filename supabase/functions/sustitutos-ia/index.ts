// Edge Function `sustitutos-ia` — llena sustitutos_internos/externos de los LÍDERES
// (canónicos y derivados): internos elegidos SOLO de la lista de candidatos que arma SQL
// (misma categoría, sin familia); externos buscados en la web (mercado peruano).
// AUTORIZACIÓN: header `x-cron-secret` == CRON_SECRET (deploy --no-verify-jwt).
const ENDPOINT = 'https://api.anthropic.com/v1/messages';
// [852] CONTABILIDAD DE IA — registra tokens y costo de cada llamada a Claude.
// Nunca lanza: si el registro falla, la IA sigue funcionando igual.
function _iaLog(rec: Record<string, unknown>): void {
  try {
    const _u = Deno.env.get('SUPABASE_URL');
    const _k = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!_u || !_k) return;
    fetch(`${_u}/rest/v1/rpc/ia_registrar_uso`, {
      method: 'POST',
      headers: { apikey: _k, Authorization: 'Bearer ' + _k,
                 'Content-Type': 'application/json', 'Content-Profile': 'mos' },
      body: JSON.stringify({ p: rec }),
    }).catch(() => {});
  } catch { /* contabilizar jamás rompe la operación */ }
}

import { geminiMessages, proveedorIA, GEMINI_FLASH } from '../_shared/gemini.ts';
const MODELO = 'claude-haiku-4-5-20251001';

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { 'Content-Type': 'application/json' } });
}

async function rpc(fn: string, p: unknown): Promise<any> {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: key!, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json',
      'Accept-Profile': 'mos', 'Content-Profile': 'mos' },
    body: JSON.stringify({ p }),
  });
  if (!r.ok) throw new Error(`${fn} HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return r.json();
}

// dieta de tokens: de la ficha solo van las líneas útiles para sustituir (qué es, envase, uso)
function fichaCorta(f: unknown): string {
  return String(f || '').split('\n').filter((l) => /^(🧪|📦|✅)/.test(l)).join(' ').slice(0, 380);
}

function prompt(prod: any): string {
  // [rev.13] la subcategoría del candidato (cuando difiere) ayuda a elegir del mismo palo
  const cands = (prod.candidatos || []).map((c: any, i: number) =>
    `${i + 1}. ${c.nombre}${c.sub && c.sub !== prod.subcategoria ? ` [${c.sub}]` : ''}`).join('\n');
  return `Eres experto en abarrotes e insumos de cocina del mercado PERUANO. Un cliente pide este producto y NO hay stock; hay que sugerir SUSTITUTOS (producto lo más parecido en función, uso, formato y tamaño — JAMÁS el mismo producto en otro tamaño).

PRODUCTO:
NOMBRE: ${prod.descripcion}
MARCA: ${prod.marca || '(sin marca / TONYS = envasado propio)'}
CATEGORÍA: ${prod.categoria} > ${prod.subcategoria}
FICHA: ${fichaCorta(prod.ficha)}

CANDIDATOS DEL CATÁLOGO PROPIO (para los INTERNOS elige SOLO de aquí, por su número):
${cands || '(sin candidatos)'}

TAREAS:
A) INTERNOS: elige 1 a 3 candidatos que mejor sustituyan al producto (misma función y formato similar: granel↔granel, empaquetado↔empaquetado de tamaño parecido). Si ninguno sirve de verdad, lista vacía.
B) EXTERNOS: busca en la web (UNA sola búsqueda, aprovéchala bien) 1 a 3 productos del mercado peruano MUY parecidos que NO estén en la lista de candidatos (otra marca comercial, presentación similar) — sirven para que el comprador los consiga.

RESPONDE ÚNICAMENTE este JSON, sin texto antes ni después:
{"internos":[{"n":1,"motivo":"..."}],"externos":[{"nombre":"...","marca":"...","presentacion":"...","motivo":"..."}]}`;
}


// [IA · Gemini 19-ago-2026] mismo contrato que Claude (payload estilo Anthropic → respuesta con content[].text y
// usage). El proveedor lo decide mos.config.IA_PROVEEDOR / la clave disponible. `conWeb` → grounding de Google.
async function llamarIA(key: string, payload: Record<string, unknown>, conWeb: boolean, modeloGemini: string):
    Promise<{ ok: boolean; status: number; d: any; proveedor: string }> {
  const prov = await proveedorIA();
  const gkey = Deno.env.get('GEMINI_API_KEY') || '';
  if (prov === 'gemini' && gkey) {
    const g = await geminiMessages({ key: gkey, model: modeloGemini, system: payload.system ? String(payload.system) : undefined,
                                     messages: payload.messages as any, max_tokens: Number(payload.max_tokens) || 1024,
                                     grounding: conWeb, timeoutMs: 60000 });
    return { ok: g.ok, status: g.status, d: g.data || { error: { message: g.error || 'gemini' } }, proveedor: 'gemini' };
  }
  const r = await fetch(ENDPOINT, {
    method: 'POST',
    headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(60_000),
  });
  const d = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, d, proveedor: 'anthropic' };
}

async function generar(key: string, prod: any): Promise<{ internos: any[]; externos: any[] }> {
  const base = { model: MODELO, max_tokens: 700, messages: [{ role: 'user', content: prompt(prod) }] };
  // fallback SIN web SOLO si la herramienta no está disponible — jamás por formato malo
  // (eso pagaba una 2ª llamada completa) [rev.2/6]
  for (const conWeb of [true, false]) {
    const payload = conWeb
      ? { ...base, tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 1 }] }
      : base;
    const _t0ia = Date.now();
    const r = await llamarIA(key, payload, conWeb, GEMINI_FLASH);
    const d = r.d || {};
    // [852] contabilidad — también los intentos fallidos: consumieron tokens de entrada igual
    _iaLog({ app: 'cron', funcion: conWeb ? 'sustitutosIA (con web)' : 'sustitutosIA',
             modelo: String(d.model || (r.proveedor === 'gemini' ? GEMINI_FLASH : MODELO)), ok: r.ok, ms: Date.now() - _t0ia,
             usage: d.usage || {}, error: r.ok ? '' : JSON.stringify(d).slice(0, 300),
             meta: { conWeb, stop: d.stop_reason || '', proveedor: r.proveedor,
                     websearch: ((d.usage || {}).server_tool_use || {}).web_search_requests || 0 } });
    if (!r.ok) {
      const msg = JSON.stringify(d);
      if (conWeb && r.status === 400 && /web_search|tool|google_search|grounding/i.test(msg)) continue;
      throw new Error(`${r.proveedor} ${r.status}: ${msg.slice(0, 160)}`);
    }
    // [rev.5] respuesta truncada = fallo (mejor reintentar por cola que guardar a medias)
    if (d.stop_reason === 'max_tokens' || d.stop_reason === 'pause_turn') {
      throw new Error('respuesta truncada: ' + d.stop_reason);
    }
    const texto = (d.content || []).filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n');
    const i0 = texto.indexOf('{'), i1 = texto.lastIndexOf('}');
    if (i0 < 0 || i1 <= i0) throw new Error('sin JSON en la respuesta');
    try {
      const obj = JSON.parse(texto.slice(i0, i1 + 1));
      // mapear índices → candidatos reales (la IA no puede inventar skus)
      const vistos = new Set<string>();
      const internos = (Array.isArray(obj.internos) ? obj.internos : []).map((x: any) => {
        const cd = (prod.candidatos || [])[Number(x.n) - 1];
        if (!cd || !cd.cod || vistos.has(cd.cod)) return null;   // [rev.8] sin internos fantasma
        vistos.add(cd.cod);
        return { cod: cd.cod, motivo: String(x.motivo || '').slice(0, 140) };
      }).filter(Boolean).slice(0, 3);
      const externos = (Array.isArray(obj.externos) ? obj.externos : []).map((x: any) => ({
        nombre: String(x.nombre || '').slice(0, 120), marca: String(x.marca || '').slice(0, 60),
        presentacion: String(x.presentacion || '').slice(0, 90), motivo: String(x.motivo || '').slice(0, 140),
      })).filter((x: any) => x.nombre).slice(0, 3);
      return { internos, externos };
    } catch (_e) {
      if (!conWeb) throw new Error('JSON inválido en la respuesta');
    }
  }
  throw new Error('sin respuesta');
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const secret = Deno.env.get('CRON_SECRET') || '';
  if (!secret || req.headers.get('x-cron-secret') !== secret) return json({ ok: false, error: 'no autorizado' }, 401);
  const key = Deno.env.get('ANTHROPIC_API_KEY') || '';
  if (!key && !Deno.env.get('GEMINI_API_KEY')) return json({ ok: false, error: 'sin GEMINI_API_KEY ni ANTHROPIC_API_KEY' }, 500);
  try {
    const body = await req.json().catch(() => ({}));
    const max = Math.min(Math.max(parseInt(String(body.max)) || 2, 1), 5);
    const pendientes = await rpc('sust_pendientes', { max });
    if (!Array.isArray(pendientes) || !pendientes.length) return json({ ok: true, procesados: 0, nota: 'sin pendientes' });
    // anti-bucle: los tomados suben intento YA (si fallan, se hunden en la cola)
    await rpc('sust_marcar_intento', { codigos: pendientes.map((p: any) => p.codigo_barra) });

    const hechos: any[] = [], fallos: any[] = [];
    for (const prod of pendientes) {
      try {
        const { internos, externos } = await generar(key, prod);
        const g = await rpc('sust_guardar', { codigoBarra: prod.codigo_barra, internos, externos });
        if (g && g.ok) hechos.push({ cod: prod.codigo_barra, int: g.internos, ext: g.externos });
        else fallos.push({ cod: prod.codigo_barra, error: (g && g.error) || 'guardar falló' });
      } catch (e) {
        fallos.push({ cod: prod.codigo_barra, error: String((e as Error).message).slice(0, 120) });
      }
    }
    return json({ ok: true, procesados: hechos.length, hechos, fallos });
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message).slice(0, 200) }, 500);
  }
});
