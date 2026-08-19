// [IA · Gemini] Adaptador compartido: habla con Gemini (clave de AI Studio) con el MISMO contrato que
// las apps ya usan para Claude. El navegador arma `messages` estilo Anthropic (texto, imagen base64,
// documento PDF base64) y lee `content[].text` + `usage`; acá se traduce ida y vuelta, así MOS/WH/ME
// no cambian ni una línea.
//
// SECRET: supabase secrets set GEMINI_API_KEY=<clave de AI Studio> --project-ref rzbzdeipbtqkzjqdchqk
//
// Modelos (precio por millón, ago-2026): 2.5 Flash $0.30/$2.50 · Flash-Lite $0.10/$0.40 · Pro $1.25/$10.
// Con el tier gratis de AI Studio el costo es 0 dentro de los límites diarios.

// Probado con la clave del dueño (19-ago-2026, tier gratis):
//   · gemini-2.5-flash: visión ✓, JSON ✓, grounding Google ✓ — cupo gratis 5 req/min por modelo.
//   · gemini-flash-latest (= 3.x flash): visión ✓, JSON ✓, grounding ✗ (429 en gratis) — cupo PROPIO.
//   · 2.5-flash-lite / 2.5-pro: "no disponible para usuarios nuevos".
// Como el cupo es POR MODELO, el front y los crones con web usan 2.5-flash, y el OCR de guías (sin web)
// usa flash-latest para no pelearle el minuto al cajero.
export const GEMINI_FLASH  = 'gemini-2.5-flash';
export const GEMINI_LATEST = 'gemini-flash-latest';
export const GEMINI_LITE   = GEMINI_LATEST;   // alias histórico: "el barato" hoy es el latest (lite no está para esta clave)
export const GEMINI_PRO    = 'gemini-pro-latest';
const GEMINI_OK = new Set([GEMINI_FLASH, GEMINI_LATEST, GEMINI_PRO, 'gemini-3.7-flash', 'gemini-3.5-flash', 'gemini-3.5-flash-lite', 'gemini-flash-lite-latest']);

/** Un modelo pedido "a la Claude" → su equivalente Gemini. Lo que ya es Gemini pasa tal cual. */
export function mapearModelo(pedido: unknown, porDefecto = GEMINI_FLASH): string {
  const m = String(pedido || '');
  if (GEMINI_OK.has(m)) return m;
  if (/opus/i.test(m)) return GEMINI_PRO;           // lo "caro" de Claude → Pro (nadie lo usa hoy)
  return porDefecto;                                // haiku / sonnet / vacío → Flash (visión, PDF, JSON)
}

type Bloque = { type?: string; text?: string; source?: { type?: string; media_type?: string; data?: string } };
type Mensaje = { role?: string; content?: string | Bloque[] };

function parteDe(b: Bloque | string): Record<string, unknown> | null {
  if (typeof b === 'string') return { text: b };
  if (!b || typeof b !== 'object') return null;
  if (b.type === 'text') return { text: String(b.text || '') };
  if ((b.type === 'image' || b.type === 'document') && b.source && b.source.type === 'base64') {
    return { inlineData: { mimeType: String(b.source.media_type || (b.type === 'document' ? 'application/pdf' : 'image/jpeg')),
                           data: String(b.source.data || '').replace(/^data:[^;]+;base64,/, '') } };
  }
  return null;
}

export type GeminiOpts = {
  key: string;
  model?: string;
  system?: string;
  messages: Mensaje[];
  max_tokens?: number;
  temperature?: number;
  json?: boolean;            // salida JSON (responseMimeType) — NO combinable con grounding
  schema?: unknown;          // responseSchema opcional (con json)
  grounding?: boolean;       // Google Search (reemplaza el web_search de Claude)
  pensar?: number;           // thinkingBudget (0 = sin pensar: más rápido y barato; Pro exige ≥128)
  timeoutMs?: number;
};

export type GeminiResp = {
  ok: boolean; status: number; error?: string;
  data?: Record<string, unknown>;   // con forma Anthropic: { model, content:[{type:'text',text}], stop_reason, usage:{input_tokens,output_tokens} }
  raw?: unknown;
};

/** Llama a Gemini y devuelve la respuesta con forma Anthropic (content[].text, usage.input_tokens/output_tokens). */
export async function geminiMessages(o: GeminiOpts): Promise<GeminiResp> {
  // Cadena de modelos: el pedido y, si falla por cupo (429) o porque ya no existe (404), el alterno
  // (cupo propio). Con grounding NO se alterna: en el tier gratis solo 2.5-flash lo tiene.
  const primero = mapearModelo(o.model);
  const cadena = o.grounding ? [primero] : [primero, primero === GEMINI_FLASH ? GEMINI_LATEST : GEMINI_FLASH];
  let ultimo: GeminiResp = { ok: false, status: 0, error: 'sin intento' };
  for (const model of cadena) {
    ultimo = await _geminiUna({ ...o, model });
    // se cortó por tope de salida SIN texto: el presupuesto se lo comió el "pensar" (pasa con topes chicos)
    // → UNA vez más, mismo modelo, con más aire (+1024)
    if (!ultimo.ok && ultimo.status === 598) ultimo = await _geminiUna({ ...o, model, max_tokens: (o.max_tokens || 1024) + 1024 });
    if (ultimo.ok) return ultimo;
    // cupo (429), modelo que ya no existe (404), sobrecarga (5xx: "high demand") o red → probar el alterno
    if (!(ultimo.status === 429 || ultimo.status === 404 || ultimo.status >= 500 || ultimo.status === 0)) return ultimo;
  }
  return ultimo;
}
async function _geminiUna(o: GeminiOpts): Promise<GeminiResp> {
  const model = String(o.model);
  const contents: Record<string, unknown>[] = [];
  for (const m of (o.messages || [])) {
    const role = (m.role === 'assistant' || m.role === 'model') ? 'model' : 'user';
    const partes: Record<string, unknown>[] = [];
    if (typeof m.content === 'string') partes.push({ text: m.content });
    else if (Array.isArray(m.content)) for (const b of m.content) { const p = parteDe(b); if (p) partes.push(p); }
    if (partes.length) contents.push({ role, parts: partes });
  }
  if (!contents.length) return { ok: false, status: 400, error: 'sin contenido' };

  const generationConfig: Record<string, unknown> = {
    maxOutputTokens: Math.min(Math.max(o.max_tokens || 1024, 1), 65536),
    temperature: typeof o.temperature === 'number' ? o.temperature : 0.2,
  };
  if (o.json && !o.grounding) { generationConfig.responseMimeType = 'application/json'; if (o.schema) generationConfig.responseSchema = o.schema; }
  // 2.5 Flash piensa por defecto (tokens y latencia de más): para OCR/listas/JSON no hace falta.
  // Solo la familia 2.5 acepta thinkingBudget; los 3.x devuelven 400 con ese campo.
  if (/^gemini-2\.5-/.test(model) && model !== 'gemini-2.5-pro') generationConfig.thinkingConfig = { thinkingBudget: typeof o.pensar === 'number' ? o.pensar : 0 };

  const body: Record<string, unknown> = { contents, generationConfig };
  if (o.system) body.systemInstruction = { parts: [{ text: String(o.system) }] };
  if (o.grounding) body.tools = [{ google_search: {} }];

  const ctrl = new AbortController();
  const tid = setTimeout(() => ctrl.abort(), o.timeoutMs || 90000);
  let r: Response; let text = '';
  try {
    r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST', signal: ctrl.signal,
      headers: { 'x-goog-api-key': o.key, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    text = await r.text();
  } catch (e) {
    clearTimeout(tid);
    return { ok: false, status: 0, error: 'gemini red: ' + String((e as Error)?.message || e) };
  }
  clearTimeout(tid);
  let d: Record<string, unknown> = {};
  try { d = JSON.parse(text); } catch { /* no-JSON */ }
  if (!r.ok) {
    const msg = String(((d as Record<string, unknown>).error as Record<string, unknown> | undefined)?.message || text || r.status).slice(0, 400);
    return { ok: false, status: r.status, error: 'gemini ' + r.status + ': ' + msg, raw: d };
  }
  const cand = (Array.isArray(d.candidates) ? d.candidates[0] : null) as Record<string, unknown> | null;
  const partes = ((cand?.content as Record<string, unknown> | undefined)?.parts as Record<string, unknown>[] | undefined) || [];
  const salida = partes.filter((p) => typeof p.text === 'string' && !p.thought).map((p) => String(p.text)).join('');
  const fin = String(cand?.finishReason || '');
  const um = (d.usageMetadata || {}) as Record<string, number>;
  const anthropicLike = {
    id: 'gemini_' + Date.now(),
    model: String(d.modelVersion || model),   // la versión REAL (gemini-3.7-flash), no el alias: así la tarifa calza
    role: 'assistant',
    content: [{ type: 'text', text: salida }],
    stop_reason: fin === 'MAX_TOKENS' ? 'max_tokens' : (fin === 'SAFETY' || fin === 'RECITATION' ? 'refusal' : 'end_turn'),
    usage: {
      input_tokens:  um.promptTokenCount || 0,
      output_tokens: (um.candidatesTokenCount || 0) + (um.thoughtsTokenCount || 0),
      cache_read_input_tokens: um.cachedContentTokenCount || 0,
    },
    // rastro de grounding (fuentes) por si alguna función quiere mostrarlas
    ...(cand?.groundingMetadata ? { grounding: cand.groundingMetadata } : {}),
  };
  if (!salida && fin === 'MAX_TOKENS') return { ok: false, status: 598, error: 'gemini sin texto (MAX_TOKENS)', data: anthropicLike, raw: d };
  if (!salida && fin && fin !== 'STOP') return { ok: false, status: 502, error: 'gemini sin texto (' + fin + ')', data: anthropicLike, raw: d };
  return { ok: true, status: 200, data: anthropicLike, raw: d };
}

/** Proveedor activo: mos.config IA_PROVEEDOR ('gemini' | 'anthropic'); por defecto gemini si hay clave. Cache 60 s. */
let _provCache: { v: string; t: number } | null = null;
export async function proveedorIA(): Promise<'gemini' | 'anthropic'> {
  const tieneG = !!Deno.env.get('GEMINI_API_KEY'), tieneA = !!Deno.env.get('ANTHROPIC_API_KEY');
  if (_provCache && Date.now() - _provCache.t < 60000) return (_provCache.v === 'anthropic' && tieneA) || !tieneG ? 'anthropic' : 'gemini';
  let v = '';
  try {
    const u = Deno.env.get('SUPABASE_URL'), k = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (u && k) {
      const r = await fetch(`${u}/rest/v1/config?select=valor&clave=eq.IA_PROVEEDOR&limit=1`, {
        headers: { apikey: k, Authorization: 'Bearer ' + k, 'Accept-Profile': 'mos' } });
      const j = await r.json().catch(() => []);
      v = String((Array.isArray(j) && j[0] && j[0].valor) || '').trim().toLowerCase();
    }
  } catch { /* sin config: por defecto */ }
  _provCache = { v, t: Date.now() };
  if (v === 'anthropic' && tieneA) return 'anthropic';
  if (!tieneG) return 'anthropic';
  return 'gemini';
}
