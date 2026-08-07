// 646 · Foto PROPIA para presentaciones y derivados (decisión dueño): set_foto_producto
// acepta idProducto opcional → actualiza SOLO esa fila (la presentación comparte sku con el
// líder; sin esto, su foto pisaba a toda la familia). Sin idProducto = comportamiento legacy.
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
    -- [646] foto INDIVIDUAL (presentación/derivado): solo esa fila
    update mos.productos set foto_url = v_url, updated_at = now() where id_producto = v_id;
  else
    if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase o idProducto requerido'); end if;
    update mos.productos set foto_url = v_url, updated_at = now() where sku_base = v_sku;
  end if;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('skuBase', v_sku, 'idProducto', v_id,
    'fotoUrl', v_url, 'actualizados', coalesce(v_n,0)));
end; $function$`;
await c.query('begin');
await c.query(SQL);
const pres = (await c.query(`select id_producto, sku_base from mos.productos where tipo_producto::text='PRESENTACION' limit 1`)).rows[0];
const r1 = (await c.query(`select mos.set_foto_producto($1::jsonb) r`, [JSON.stringify({ idProducto: pres.id_producto, fotoUrl: 'https://test/646.png' })])).rows[0].r;
const chk = (await c.query(`select
  (select foto_url from mos.productos where id_producto=$1) mia,
  (select count(*) from mos.productos where sku_base=$2 and foto_url='https://test/646.png') n`, [pres.id_producto, pres.sku_base])).rows[0];
console.log('individual:', JSON.stringify(r1.data), '· solo 1 fila tocada:', chk.mia === 'https://test/646.png' && Number(chk.n) === 1);
if (!(r1.ok && chk.mia === 'https://test/646.png' && Number(chk.n) === 1)) { console.log('❌'); await c.query('rollback'); process.exit(1); }
await c.query('rollback');
await c.query(SQL);
console.log('✅ 646 aplicado');
await c.end();
