// 646b · La foto FAMILIAR (subida desde el líder, sin idProducto) ya NO pisa fotos PROPIAS
// de presentaciones/derivados. Distinción: las fotos propias llevan el id_producto en la URL
// (el archivo de Storage se nombra con él desde 697); las familiares llevan el sku.
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
    -- [646b] familiar: respeta fotos PROPIAS (URL con el id_producto de esa fila)
    update mos.productos set foto_url = v_url, updated_at = now()
     where sku_base = v_sku
       and (foto_url is null or position(id_producto in foto_url) = 0);
  end if;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('skuBase', v_sku, 'idProducto', v_id,
    'fotoUrl', v_url, 'actualizados', coalesce(v_n,0)));
end; $function$`;
await c.query('begin');
await c.query(SQL);
// test: pres con foto PROPIA sobrevive al guardado familiar; hermana sin propia sí cambia
const fam = (await c.query(`select p.sku_base, array_agg(p.id_producto) ids from mos.productos p
  where p.tipo_producto::text='PRESENTACION' group by p.sku_base having count(*)>=2 limit 1`)).rows[0];
const [a, b] = fam.ids;
await c.query(`select mos.set_foto_producto($1::jsonb)`, [JSON.stringify({ idProducto: a, fotoUrl: 'https://x/propia-' + a + '.png' })]);
await c.query(`select mos.set_foto_producto($1::jsonb)`, [JSON.stringify({ skuBase: fam.sku_base, fotoUrl: 'https://x/familiar.png' })]);
const r = (await c.query(`select id_producto, foto_url from mos.productos where id_producto = any($1)`, [[a, b]])).rows;
const propia = r.find(x => x.id_producto === a).foto_url, herm = r.find(x => x.id_producto === b).foto_url;
console.log('propia sobrevive:', propia.includes('propia-' + a), '· hermana hereda:', herm === 'https://x/familiar.png');
if (!(propia.includes('propia-' + a) && herm === 'https://x/familiar.png')) { console.log('❌'); await c.query('rollback'); process.exit(1); }
await c.query('rollback');
await c.query(SQL);
console.log('✅ 646b aplicado — la foto del líder jamás pisa una propia');
await c.end();
