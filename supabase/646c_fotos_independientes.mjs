// 646c · REGLA FINAL del dueño: imágenes INDEPENDIENTES por producto (canónico,
// presentación y derivado). El camino legacy por skuBase ya no pinta a la familia:
// actualiza SOLO al canónico de ese sku (compat con llamadas viejas).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const SQL = String.raw`
create or replace function mos.set_foto_producto(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_id   text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_url  text := nullif(btrim(coalesce(p->>'fotoUrl','')), '');
  v_n    int;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_url is null then return jsonb_build_object('ok',false,'error','fotoUrl requerido'); end if;

  if v_id is not null then
    update mos.productos set foto_url = v_url, updated_at = now() where id_producto = v_id;
  else
    if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase o idProducto requerido'); end if;
    -- [646c] legacy por sku: SOLO el canónico (jamás pinta a la familia)
    update mos.productos set foto_url = v_url, updated_at = now()
     where sku_base = v_sku and tipo_producto::text = 'CANONICO';
  end if;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('skuBase', v_sku, 'idProducto', v_id,
    'fotoUrl', v_url, 'actualizados', coalesce(v_n,0)));
end; $function$`;
await c.query('begin');
await c.query(SQL);
const fam = (await c.query(`select c2.sku_base, c2.id_producto canon, p2.id_producto pres from mos.productos c2
  join mos.productos p2 on p2.sku_base=c2.sku_base and p2.tipo_producto::text='PRESENTACION'
  where c2.tipo_producto::text='CANONICO' limit 1`)).rows[0];
await c.query(`select mos.set_foto_producto($1::jsonb)`, [JSON.stringify({ skuBase: fam.sku_base, fotoUrl: 'https://x/solo-canon.png' })]);
const r = (await c.query(`select
  (select foto_url from mos.productos where id_producto=$1) canon,
  (select foto_url from mos.productos where id_producto=$2) pres`, [fam.canon, fam.pres])).rows[0];
console.log('canónico cambió:', r.canon === 'https://x/solo-canon.png', '· presentación INTACTA:', r.pres !== 'https://x/solo-canon.png');
if (!(r.canon === 'https://x/solo-canon.png' && r.pres !== 'https://x/solo-canon.png')) { console.log('❌'); await c.query('rollback'); process.exit(1); }
await c.query('rollback');
await c.query(SQL);
console.log('✅ 646c aplicado — fotos independientes');
await c.end();
