// Edge Function `descripcion-ia` — llena mos.productos.descripcion_ia de los canónicos
// NUEVOS (≤7 días) automáticamente: busca en la web (Claude Haiku + web_search) y guarda
// la ficha de 6 líneas (🏷 Marca … ✅ Usos). La dispara un cron pg_net cada 10 min.
//
// AUTORIZACIÓN: header `x-cron-secret` == secret CRON_SECRET (deploy con --no-verify-jwt;
// esta función NO la llaman los navegadores). Las RPCs que usa están grant SOLO service_role.
//
// SECRETS: ANTHROPIC_API_KEY (ya existe) · CRON_SECRET (nuevo).
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

function prompt(prod: { codigo_barra: string; descripcion: string; equivalentes: string }): string {
  const eans = [prod.codigo_barra, ...(prod.equivalentes || '').split(',')].map(s => s.trim())
    .filter(s => /^\d{8,13}$/.test(s));
  return `Producto de una distribuidora de abarrotes/insumos de cocina en Perú:
NOMBRE: ${prod.descripcion}
${eans.length ? 'CÓDIGO(S) DE BARRA EAN: ' + eans.join(', ') : 'SIN código EAN público (producto interno/granel).'}

Busca en la web (máximo 2 búsquedas: primero el EAN si hay, luego "${prod.descripcion} Perú producto") y redacta EXACTAMENTE estas 6 líneas en español neutral (jamás voseo), máximo ~900 caracteres en total, sin nada antes ni después:
🏷 Marca: <marca comercial real, o "sin marca (granel/genérico)">
🧪 Hecho de: <de qué está hecho>
📋 Composición: <ingredientes/composición>
📦 Presentación: <cómo viene: envase, tamaño, forma en que se vende>
🎨 Características: <colores, formas, aspecto del producto y su empaque>
✅ Usos y beneficios: <para qué sirve, en qué ayuda>

Si no encuentras ficha específica, descríbelo con conocimiento general del tipo de producto y agrega al final de la línea ✅: " (descripción general del tipo de producto — sin ficha web específica)". No inventes datos regulatorios.`;
}

async function generar(key: string, prod: any): Promise<{ texto: string; conWeb: boolean }> {
  const base = {
    model: MODELO, max_tokens: 1200,
    messages: [{ role: 'user', content: prompt(prod) }],
  };
  // 1º intento CON búsqueda web; si la herramienta no está disponible, fallback sin ella.
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
      if (conWeb) continue;               // sin web_search → reintenta pelado
      throw new Error(`anthropic ${r.status}: ${JSON.stringify(d).slice(0, 180)}`);
    }
    let texto = (d.content || []).filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n').trim();
    // Normalizar: las citas de la búsqueda web parten líneas a la mitad. Se re-arma en
    // EXACTAMENTE 6 renglones (uno por emoji), espacios colapsados.
    texto = texto.replace(/\s*\n\s*/g, ' ').replace(/\s*(🏷|🧪|📋|📦|🎨|✅)/g, '\n$1').trim();
    if (texto.includes('🏷') && texto.includes('✅')) return { texto, conWeb };
    if (!conWeb) throw new Error('respuesta sin el formato 🏷…✅');
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
    const pendientes = await rpc('ia_desc_pendientes', { max });
    if (!Array.isArray(pendientes) || !pendientes.length) return json({ ok: true, procesados: 0, nota: 'sin pendientes recientes' });

    const hechos: any[] = [], fallos: any[] = [];
    for (const prod of pendientes) {
      try {
        const { texto, conWeb } = await generar(key, prod);
        // la marca para el minicampo: 1ª línea "🏷 Marca: X" (solo si es comercial real)
        const m = /🏷\s*Marca:\s*(.+)/.exec(texto);
        let marca = (m ? m[1] : '').trim();
        if (/sin marca|gen[eé]rico|granel/i.test(marca)) marca = '';
        const g = await rpc('ia_guardar_descripcion', { codigoBarra: prod.codigo_barra, texto, marca });
        if (g && g.ok) hechos.push({ cod: prod.codigo_barra, web: conWeb });
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
