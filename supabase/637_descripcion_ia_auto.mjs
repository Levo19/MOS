// 637 · AUTOMATIZACIÓN de descripcion_ia para productos NUEVOS (decisión dueño):
// cuando entra un canónico (por PN aprobado o +producto del catálogo), un cron cada
// 10 min manda los pendientes RECIENTES (≤7 días) a la Edge `descripcion-ia`, que busca
// en la web (Claude Haiku + web_search) y llena el campo. El backlog histórico lo comen
// los agentes por lotes; este circuito es el guardián de lo nuevo.
//
// RPCs (SOLO service_role — ni anon ni authenticated pueden tocarlas):
//   mos.ia_desc_pendientes(p{max})            → canónicos nuevos sin descripcion_ia
//   mos.ia_guardar_descripcion(p{codigoBarra,texto,marca}) → guarda SIN bump de catálogo
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const PEND = String.raw`
create or replace function mos.ia_desc_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object(
             'codigo_barra', pr.codigo_barra,
             'descripcion',  pr.descripcion,
             'marca_actual', coalesce(nullif(btrim(pr.marca),''),''),
             'equivalentes', coalesce((select string_agg(e.codigo_barra, ', ')
                                         from mos.equivalencias e
                                        where e.sku_base = pr.sku_base and e.activo), '')
           ) as x
      from mos.productos pr
     where pr.tipo_producto::text = 'CANONICO'
       and coalesce(pr.estado, true) = true
       and pr.descripcion_ia is null
       and coalesce(pr.es_insumo, false) = false
       and length(btrim(pr.descripcion)) >= 6
       and pr.descripcion !~* '^[0-9 .,x*/-]+\s*(metros?|unidades?|mil(lar)?|cm|mm|gr?|kg|ml|lt|litros?)?\.?\s*$'
       and coalesce(pr.fecha_creacion, pr.created_at) > now() - interval '7 days'   -- solo lo NUEVO (el backlog es de los agentes)
     order by coalesce(pr.fecha_creacion, pr.created_at) desc
     limit least(greatest(coalesce((p->>'max')::int, 2), 1), 5)
  ) t;
$fn$;
revoke all on function mos.ia_desc_pendientes(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_desc_pendientes(jsonb) to service_role;`;

const GUARDAR = String.raw`
create or replace function mos.ia_guardar_descripcion(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_txt text := coalesce(p->>'texto','');
  v_marca text := btrim(coalesce(p->>'marca',''));
  v_n int;
begin
  if v_cod = '' then return jsonb_build_object('ok',false,'error','codigoBarra requerido'); end if;
  -- guard de formato: las 6 líneas (🏷 … ✅) o no se guarda
  if length(v_txt) < 60 or position('🏷' in v_txt) = 0 or position('✅' in v_txt) = 0 then
    return jsonb_build_object('ok',false,'error','FORMATO: faltan las líneas 🏷…✅');
  end if;
  -- sin bump de catálogo: las cajas no re-descargan por una descripción
  set local session_replication_role = replica;
  update mos.productos
     set descripcion_ia = v_txt,
         marca = case when nullif(btrim(coalesce(marca,'')),'') is null and v_marca <> ''
                      then v_marca else marca end
   where codigo_barra = v_cod and tipo_producto::text = 'CANONICO';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n = 1, 'actualizados', v_n);
end; $fn$;
revoke all on function mos.ia_guardar_descripcion(jsonb) from public, anon, authenticated;
grant execute on function mos.ia_guardar_descripcion(jsonb) to service_role;`;

await c.query('begin');
await c.query(PEND); await c.query(GUARDAR);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

// pendientes recientes (los agentes están comiendo el backlog viejo; esto solo ve ≤7d)
const pend = (await c.query(`select mos.ia_desc_pendientes('{"max":5}'::jsonb) r`)).rows[0].r;
chk('lista pendientes recientes (≤7 días)', Array.isArray(pend), 'n=' + (pend?.length ?? '?'));

// guardar con formato válido sobre un producto real reciente (si hay) — en tx, se revierte
if (pend.length) {
  const cod = pend[0].codigo_barra;
  const txt = '🏷 Marca: prueba\n🧪 Hecho de: prueba\n📋 Composición: prueba\n📦 Presentación: prueba\n🎨 Características: prueba de formato con longitud suficiente\n✅ Usos y beneficios: prueba';
  const g = (await c.query(`select mos.ia_guardar_descripcion($1::jsonb) r`, [JSON.stringify({ codigoBarra: cod, texto: txt, marca: '' })])).rows[0].r;
  chk('guarda con formato válido', g.ok === true, JSON.stringify(g));
  const g2 = (await c.query(`select mos.ia_guardar_descripcion($1::jsonb) r`, [JSON.stringify({ codigoBarra: cod, texto: 'muy corto' })])).rows[0].r;
  chk('rechaza texto sin formato', g2.ok === false && /FORMATO/.test(g2.error || ''), JSON.stringify(g2));
} else {
  console.log('  (sin pendientes recientes para probar guardado — ok igual)');
}
// permisos: anon NO puede
const perm = (await c.query(`select has_function_privilege('anon', 'mos.ia_guardar_descripcion(jsonb)', 'execute') pe,
  has_function_privilege('service_role', 'mos.ia_guardar_descripcion(jsonb)', 'execute') ps`)).rows[0];
chk('anon bloqueado · service_role permitido', perm.pe === false && perm.ps === true, JSON.stringify(perm));

t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 90) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} — NO se aplica`); await c.end(); process.exit(1); }
await c.query(PEND); await c.query(GUARDAR);
console.log(`\n✅ ${t.length}/${t.length} — RPCs 637 aplicadas`);
fs.writeFileSync('637_descripcion_ia_auto.sql', PEND + '\n\n' + GUARDAR);
await c.end();
