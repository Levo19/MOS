// Edge Function `descripcion-ia` — llena mos.productos.descripcion_ia de los canónicos
// NUEVOS (≤7 días) automáticamente: busca en la web (Claude Haiku + web_search) y guarda
// la ficha (🏷 Marca … ✅ Usos + línea 🗂 de categoría que se extrae). Cron pg_net cada 10 min.
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

Busca en la web (máximo 2 búsquedas: primero el EAN si hay, luego "${prod.descripcion} Perú producto") y redacta EXACTAMENTE estas 7 líneas en español neutral (jamás voseo), máximo ~950 caracteres en total, sin nada antes ni después:
🏷 Marca: <marca comercial real, o "sin marca (granel/genérico)">
🧪 Hecho de: <de qué está hecho>
📋 Composición: <ingredientes/composición>
📦 Presentación: <cómo viene: envase, tamaño, forma en que se vende>
🎨 Características: <colores, formas, aspecto del producto y su empaque>
✅ Usos y beneficios: <para qué sirve, en qué ayuda>
🗂 Categoría: <CATEGORIA> > <Subcategoría>

Para la línea 🗂 usa una de estas categorías SI el producto calza: ABARROTES, ACEITES, BEBIDAS, CONFITERIA, CONSERVAS, DECORATIVOS, DESCARTABLES, ENDULZANTES, ENERGIZANTES, ESPECIAS, GALLETAS_SNACKS, GRANEL, INFUSIONES, INSUMOS_REPOSTERIA, LACTEOS, LIMPIEZA, MENESTRAS, PRODUCTOS_CHINOS, REPOSTERIA, SALSAS, VINAGRES, VINOS_LICORES. Si NO encaja en ninguna (p.ej. ferretería, textil), propone una nueva corta en MAYÚSCULAS (ej: HERRAMIENTAS). La subcategoría es libre, corta y en español (ej: Martillos).
Si no encuentras ficha específica, descríbelo con conocimiento general del tipo de producto y agrega al final de la línea ✅: " (descripción general del tipo de producto — sin ficha web específica)". No inventes datos regulatorios.`;
}

async function generar(key: string, prod: any): Promise<{ texto: string; conWeb: boolean }> {
  const base = {
    model: MODELO, max_tokens: 1200,
    messages: [{ role: 'user', content: prompt(prod) }],
  };
  // 1º intento CON búsqueda web; el fallback SIN web corre SOLO si la herramienta no está
  // disponible (400 de tool) — jamás por formato malo: eso sería pagar una 2ª llamada [rev.2/6].
  for (const conWeb of [true, false]) {
    const payload = conWeb
      ? { ...base, tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 2 }] }
      : base;
    const r = await fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(60_000),   // [rev.7] sin cuelgues que maten la Edge a mitad de lote
    });
    const d = await r.json();
    if (!r.ok) {
      const msg = JSON.stringify(d);
      if (conWeb && r.status === 400 && /web_search|tool/i.test(msg)) continue;  // herramienta no disponible
      throw new Error(`anthropic ${r.status}: ${msg.slice(0, 180)}`);
    }
    // [rev.5] truncada o pausada = fallo (una ficha a medias pasaría el guard 🏷…✅ y quedaría coja)
    if (d.stop_reason === 'max_tokens' || d.stop_reason === 'pause_turn') {
      throw new Error('respuesta truncada: ' + d.stop_reason);
    }
    let texto = (d.content || []).filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n').trim();
    // [rev.3] fuera variation selectors (🏷️ = 🏷+U+FE0F): rompían los regex de marca y 🗂
    texto = texto.replace(/\uFE0F/g, '');
    // Normalizar: las citas de la búsqueda web parten líneas a la mitad. Se re-arma en
    // renglones (uno por emoji, 7 con la línea 🗂), espacios colapsados.
    texto = texto.replace(/\s*\n\s*/g, ' ').replace(/\s*(🏷|🧪|📋|📦|🎨|✅|🗂)/g, '\n$1').trim();
    // sin preámbulos ("Basándome en la búsqueda…"): la ficha SIEMPRE arranca en 🏷
    const i0 = texto.indexOf('🏷');
    if (i0 > 0) texto = texto.slice(i0);
    if (texto.includes('🏷') && texto.includes('✅')) return { texto, conWeb };
    throw new Error('respuesta sin el formato 🏷…✅');
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
    // [638] modo REPESCA: re-busca en la web los que quedaron con "(sin ficha web
    // específica)" pese a tener EAN — el pedido del dueño exige búsqueda real.
    const fn = body.repesca === true ? 'ia_repesca_pendientes' : 'ia_desc_pendientes';
    const pendientes = await rpc(fn, { max });
    if (!Array.isArray(pendientes) || !pendientes.length) return json({ ok: true, procesados: 0, nota: 'sin pendientes' });

    const hechos: any[] = [], fallos: any[] = [];
    for (const prod of pendientes) {
      try {
        const gen = await generar(key, prod);
        const conWeb = gen.conWeb;
        let texto = gen.texto;
        // la marca para el minicampo: 1ª línea "🏷 Marca: X" (solo si es comercial real)
        const m = /🏷\s*Marca:\s*(.+)/.exec(texto);
        let marca = (m ? m[1] : '').trim();
        if (/sin marca|gen[eé]rico|granel/i.test(marca)) marca = '';
        // [640] línea 🗂 = propuesta de categoría (se EXTRAE de la ficha, no se guarda en ella)
        // [rev.9] con validación: MAYÚSCULAS reales, ≤30 chars, sin dígitos — nada de frases
        // sueltas convirtiéndose en categorías vía _tax_registrar.
        let categoriaProp = '', subcategoriaProp = '';
        const mc = /🗂\s*Categor[ií]a:\s*([^>\n]{3,40})\s*>\s*(.{3,60})/.exec(texto);
        if (mc) {
          const cat = mc[1].trim().toUpperCase().replace(/ +/g, '_');
          const sub = mc[2].trim();
          if (/^[A-ZÁÉÍÓÚÑ_]{3,30}$/.test(cat) && sub.length >= 3) {
            categoriaProp = cat; subcategoriaProp = sub;
          }
        }
        texto = texto.split('\n').filter((l: string) => !l.startsWith('🗂')).join('\n').trim();
        const g = await rpc('ia_guardar_descripcion', { codigoBarra: prod.codigo_barra, texto, marca, categoriaProp, subcategoriaProp });
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
