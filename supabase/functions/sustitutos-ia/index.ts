// Edge Function `sustitutos-ia` — llena sustitutos_internos/externos de los LÍDERES
// (canónicos y derivados): internos elegidos SOLO de la lista de candidatos que arma SQL
// (misma categoría, sin familia); externos buscados en la web (mercado peruano).
// AUTORIZACIÓN: header `x-cron-secret` == CRON_SECRET (deploy --no-verify-jwt).
const ENDPOINT = 'https://api.anthropic.com/v1/messages';
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

function prompt(prod: any): string {
  const cands = (prod.candidatos || []).map((c: any, i: number) => `${i + 1}. ${c.nombre}`).join('\n');
  return `Eres experto en abarrotes e insumos de cocina del mercado PERUANO. Un cliente pide este producto y NO hay stock; hay que sugerir SUSTITUTOS (producto lo más parecido en función, uso, formato y tamaño — JAMÁS el mismo producto en otro tamaño).

PRODUCTO:
NOMBRE: ${prod.descripcion}
MARCA: ${prod.marca || '(sin marca / TONYS = envasado propio)'}
CATEGORÍA: ${prod.categoria} > ${prod.subcategoria}
FICHA: ${String(prod.ficha || '').slice(0, 600)}

CANDIDATOS DEL CATÁLOGO PROPIO (para los INTERNOS elige SOLO de aquí, por su número):
${cands || '(sin candidatos)'}

TAREAS:
A) INTERNOS: elige 1 a 3 candidatos que mejor sustituyan al producto (misma función y formato similar: granel↔granel, empaquetado↔empaquetado de tamaño parecido). Si ninguno sirve de verdad, lista vacía.
B) EXTERNOS: busca en la web (máximo 2 búsquedas) 1 a 3 productos del mercado peruano MUY parecidos que NO estén en la lista de candidatos (otra marca comercial, presentación similar) — sirven para que el comprador los consiga.

RESPONDE ÚNICAMENTE este JSON, sin texto antes ni después:
{"internos":[{"n":1,"motivo":"..."}],"externos":[{"nombre":"...","marca":"...","presentacion":"...","motivo":"..."}]}`;
}

async function generar(key: string, prod: any): Promise<{ internos: any[]; externos: any[] }> {
  const base = { model: MODELO, max_tokens: 1000, messages: [{ role: 'user', content: prompt(prod) }] };
  for (const conWeb of [true, false]) {
    const payload = conWeb
      ? { ...base, tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 2 }] }
      : base;
    const r = await fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const d = await r.json();
    if (!r.ok) {
      if (conWeb) continue;
      throw new Error(`anthropic ${r.status}: ${JSON.stringify(d).slice(0, 160)}`);
    }
    const texto = (d.content || []).filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n');
    const i0 = texto.indexOf('{'), i1 = texto.lastIndexOf('}');
    if (i0 < 0 || i1 <= i0) { if (!conWeb) throw new Error('sin JSON en la respuesta'); continue; }
    try {
      const obj = JSON.parse(texto.slice(i0, i1 + 1));
      // mapear índices → candidatos reales (la IA no puede inventar skus)
      const vistos = new Set<string>();
      const internos = (Array.isArray(obj.internos) ? obj.internos : []).map((x: any) => {
        const cd = (prod.candidatos || [])[Number(x.n) - 1];
        if (!cd || vistos.has(cd.cod)) return null;
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
  const key = Deno.env.get('ANTHROPIC_API_KEY');
  if (!key) return json({ ok: false, error: 'sin ANTHROPIC_API_KEY' }, 500);
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
