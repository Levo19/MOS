// 650 · CACHÉ VERSIONADA del payload pesado de mos.catalogo_pos_rls (boot POS de MosExpress).
//
// MEDICIÓN (fase 1, RTT base a Supabase ≈ 106 ms):
//   catalogo_pos_rls .......... 8737–9800 ms · 1 843 347 bytes
//   productos_master_rls ......  390–421 ms · 5 771 218 bytes   ← DB no es el cuello; es el cable
//   desglose catalogo_pos_rls:
//     scan+group de mos.productos (CTE act) ....  ~5 ms de trabajo
//     loop de 1767 grupos (solo iterar) ........  ~60 ms
//     loop + subqueries jsonb_array_elements ...  ~200 ms
//     >>> HOT SPOT: los `v_pb := v_pb || ...` / `v_pr := v_pr || ...`  ≈ 9 100 ms
//         (append de jsonb es O(n²) sobre 1767 bases + 2358 presentaciones)
//     EQUIVALENCIAS / ZONAS_CONFIG / CLIENTES_FRECUENTES / STOCK_ZONAS ... ~0 ms c/u
//
// QUÉ SE CACHEA: SOLO PRODUCTO_BASE + PRESENTACIONES (lo que cuesta los 9 s).
// QUÉ NO (y por qué): se siguen calculando VIVAS en cada llamada (cuestan ~0 ms) —
//   · STOCK_ZONAS  → me.stock_zonas NO bumpea catalogo_meta (su trigger es _tg_bump_ops).
//                    Cachearlo serviría stock viejo en cada venta. JAMÁS.
//   · CLIENTES_FRECUENTES → me.clientes_frecuentes no tiene trigger de bump.
//   · ZONAS_CONFIG → depende de mos.impresoras, que NO tiene trigger de bump
//                    (estaciones y series sí, impresoras no) → PrintNode_ID quedaría viejo.
//   · EQUIVALENCIAS → sí bumpea, pero cuesta 0 ms; no vale el riesgo.
//   · _meta.timestamp → siempre now() real.
//
// CLAVE DE CACHÉ — POR QUÉ NO catalogo_meta.version (REGLA DE ORO / dinero):
//   mos._bump_catalogo_version() usa pg_try_advisory_xact_lock: si NO consigue el lock
//   SE SALTA EL BUMP ("otro writer lo hará"). Con dos writers concurrentes de precio existe
//   una ventana real en la que un cambio COMMITEADO no mueve la version → una caché keyed
//   por version serviría PRECIOS VIEJOS de forma permanente. Inaceptable.
//   → la clave es un FINGERPRINT DE CONTENIDO: md5 sobre la MISMA proyección `act` que
//     consume el payload + mos.precio_tramos. Si el hash coincide, el payload es
//     idéntico por construcción. Inmune al bump perdido y al orden de commit (MVCC).
//     Costo medido del fingerprint: ~55 ms de trabajo (159 ms con RTT).
//   version (bigint) se guarda igual en la fila, pero SOLO como dato informativo.
//
// Anti-estampida: pg_advisory_xact_lock + double-check tras el lock.
// La escritura del caché NO toca updated_at de productos ni bumpea version (sin bucle).
// Firma intacta: catalogo_pos_rls() sin args, body '{}', Content-Profile mos → CERO cambios de cliente.
// Parche sobre la def VIVA (pg_get_functiondef). Tests en begin/rollback ANTES de aplicar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
await c.query(`set statement_timeout='600s'`);

async function def(fn) {
  const r = await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname=$1 limit 1`, [fn]);
  return r.rows[0].d;
}
function patch(d, re, rep, tag) {
  if (!re.test(d)) throw new Error('ancla no encontrada: ' + tag);
  const out = d.replace(re, rep);
  if (out === d) throw new Error('no-op: ' + tag);
  return out;
}
const T = []; const chk = (n, cond, x) => { T.push([cond, n, x]); console.log(`  ${cond ? '✅' : '❌'} ${n}${x ? ' · ' + x : ''}`); return cond; };
const ms = async (sql) => { const a = Date.now(); const r = await c.query(sql); return [Date.now() - a, r.rows[0]]; };

// ───────────────────────── DDL ─────────────────────────
const DDL_TABLA = `
create table if not exists mos.catalogo_cache (
  fn          text primary key,
  version     bigint,          -- informativo (mos.catalogo_meta.version al construir)
  version_fp  text not null,   -- CLAVE REAL: fingerprint de contenido
  payload     jsonb not null,
  built_at    timestamptz not null default now(),
  build_ms    int
);
alter table mos.catalogo_cache enable row level security;  -- 0 policies: igual que mos.productos
revoke all on mos.catalogo_cache from public, anon, authenticated;
comment on table mos.catalogo_cache is '[650] Caché del tramo pesado de catalogo_pos_rls. Clave = version_fp (hash de contenido), NO catalogo_meta.version (su bump es best-effort y se puede perder). Solo la lee/escribe la funcion SECURITY DEFINER; sin grants a anon/authenticated.';
`;

// fingerprint: MISMA proyección `act` de catalogo_pos_rls + precio_tramos
const DDL_FP = `
create or replace function mos._catalogo_pos_fp() returns text
language sql stable security definer set search_path to '' as $fp$
  with act as (
    select coalesce(nullif(btrim(sku_base),''), id_producto) as sku,
           id_producto, codigo_barra, descripcion, precio_venta,
           coalesce(precio_fijo, false) as precio_fijo,
           sustitutos_internos, foto_url, categoria_ia,
           coalesce(nullif(factor_conversion,0),1) as factor,
           (coalesce(btrim(es_envasable::text),'') <> '1') as vendible,
           coalesce(es_envasable::text,'') as es_env,
           tipo_igv, unidad, unidad_medida, cod_sunat
      from mos.productos
     where coalesce(estado, true) = true)
  select md5(
      coalesce((select string_agg(h,'' order by h) from (select md5(to_jsonb(act)::text) h from act) z),'')
   || '#'
   || coalesce((select string_agg(sku_base||':'||tramos::text, ',' order by sku_base) from mos.precio_tramos),'')
  );
$fp$;
revoke all on function mos._catalogo_pos_fp() from public, anon, authenticated;
`;

// ───────────────────────── parche de catalogo_pos_rls ─────────────────────────
const BLOQUE_A = `  v_fp text; v_hit jsonb; v_t0 timestamptz;
begin
  -- [650] CACHÉ VERSIONADA POR CONTENIDO (ver 650_catalogo_cache.mjs).
  -- Solo cubre PRODUCTO_BASE + PRESENTACIONES; lo demás se calcula VIVO más abajo.
  v_fp := mos._catalogo_pos_fp();
  select payload into v_hit from mos.catalogo_cache where fn = 'catalogo_pos_rls' and version_fp = v_fp;
  if v_hit is null then
    -- anti-estampida: un solo constructor; los demás esperan y salen por el double-check
    perform pg_advisory_xact_lock(hashtext('catalogo_cache_catalogo_pos_rls'));
    select payload into v_hit from mos.catalogo_cache where fn = 'catalogo_pos_rls' and version_fp = v_fp;
  end if;
  if v_hit is not null then
    v_pb := v_hit->'PRODUCTO_BASE';
    v_pr := v_hit->'PRESENTACIONES';
  else
  v_t0 := clock_timestamp();
`;

const BLOQUE_B = `  end loop;
  -- [650] guardar con el fingerprint LEÍDO AL INICIO: si algo cambió durante los ~9 s de build,
  -- el fp vivo ya no coincide → la próxima llamada reconstruye (sobre-invalida, nunca sub-invalida).
  begin
    insert into mos.catalogo_cache as cc (fn, version, version_fp, payload, built_at, build_ms)
    values ('catalogo_pos_rls',
            (select version from mos.catalogo_meta where id = 1),
            v_fp,
            jsonb_build_object('PRODUCTO_BASE', v_pb, 'PRESENTACIONES', v_pr),
            clock_timestamp(),   -- reloj real de fin de build (now() sería el de la tx)
            (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int)
    on conflict (fn) do update set version = excluded.version, version_fp = excluded.version_fp,
           payload = excluded.payload, built_at = excluded.built_at, build_ms = excluded.build_ms;
  exception when others then null;   -- si el caché falla, la RPC igual responde (degrada, no rompe)
  end;
  end if;
`;

function patchPos(d) {
  if (/650. CACH/.test(d)) return null; // ya parchada
  d = patch(d, /\n  v_tramos_map jsonb;\nbegin\n/, `\n  v_tramos_map jsonb;\n` + BLOQUE_A, 'A declare+cache-check');
  d = patch(d, /\n  end loop;\n\n(  select coalesce\(jsonb_agg\(jsonb_build_object\('Cod_Alias')/, `\n` + BLOQUE_B + `\n$1`, 'B cierre+upsert');
  return d;
}

// md5 comparable: sin _meta.timestamp (único campo del payload que es now() del momento de build)
const MD5 = (expr) => `md5(((${expr}) #- '{data,_meta,timestamp}')::text)`;
const SECS = ['PRODUCTO_BASE', 'PRESENTACIONES', 'EQUIVALENCIAS', 'ZONAS_CONFIG', 'CLIENTES_FRECUENTES', 'STOCK_ZONAS', 'PROMOCIONES'];
const md5Secs = async (tbl) => { const o = {}; for (const k of SECS) o[k] = (await c.query(`select md5((r->'data'->'${k}')::text) m from ${tbl}`)).rows[0].m; return o; };

// ═══════════════════ TEST en begin/rollback ═══════════════════
// REPEATABLE READ: la BD es PRODUCCIÓN VIVA — me.stock_zonas cambia con cada venta.
// En READ COMMITTED cada statement toma snapshot nuevo y el md5-diff daría falsos rojos
// por tráfico real, no por el caché. Un solo snapshot ⇒ la comparación es honesta.
console.log('╔══ TEST (begin/rollback · repeatable read) ══╗');
await c.query('begin isolation level repeatable read');
try {
  // 0) payload VIVO con la función ORIGINAL (se materializa en temp, sin viajar por el cable)
  const [t_vivo1] = await ms(`create temp table _vivo on commit drop as select mos.catalogo_pos_rls() r`);
  const md5_vivo = (await c.query(`select ${MD5('r')} m, length(r::text) n from _vivo`)).rows[0];
  const s_vivo = await md5Secs('_vivo');
  console.log(`  · ORIGINAL: ${t_vivo1} ms · ${md5_vivo.n} bytes · md5=${md5_vivo.m}`);

  // 1) DDL + parche
  await c.query(DDL_TABLA);
  await c.query(DDL_FP);
  const dNew = patchPos(await def('catalogo_pos_rls'));
  if (!dNew) throw new Error('la def ya está parchada — abortar test');
  await c.query(dNew);
  chk('parche compila', true, '');

  // 2) primera llamada → REBUILD
  const [t1] = await ms(`create temp table _c1 on commit drop as select mos.catalogo_pos_rls() r`);
  const m1 = (await c.query(`select ${MD5('r')} m, length(r::text) n from _c1`)).rows[0];
  console.log(`  · CACHÉ 1ª (rebuild): ${t1} ms · ${m1.n} bytes`);

  const b1 = (await c.query(`select built_at from mos.catalogo_cache where fn='catalogo_pos_rls'`)).rows[0].built_at.toISOString();

  // 3) segunda llamada → HIT
  const [t2] = await ms(`create temp table _c2 on commit drop as select mos.catalogo_pos_rls() r`);
  const m2 = (await c.query(`select ${MD5('r')} m, length(r::text) n from _c2`)).rows[0];
  console.log(`  · CACHÉ 2ª (hit):     ${t2} ms · ${m2.n} bytes`);
  const cc = (await c.query(`select version, version_fp, build_ms, built_at from mos.catalogo_cache where fn='catalogo_pos_rls'`)).rows[0];
  console.log(`  · fila caché: version=${cc.version} fp=${cc.version_fp} build_ms=${cc.build_ms}`);
  // prueba DURA de que fue hit (no depende del reloj de una instancia compartida)
  chk('2ª llamada fue HIT real (no reconstruyó)', cc.built_at.toISOString() === b1, `built_at ${b1}`);

  // 4) MD5-DIFF INNEGOCIABLE (payload completo, solo excluyendo data._meta.timestamp)
  chk('md5(vivo) == md5(rebuild)', md5_vivo.m === m1.m, `${md5_vivo.m} vs ${m1.m}`);
  chk('md5(vivo) == md5(hit)', md5_vivo.m === m2.m, `${md5_vivo.m} vs ${m2.m}`);
  chk('bytes idénticos', md5_vivo.n === m1.n && md5_vivo.n === m2.n, `${md5_vivo.n}/${m1.n}/${m2.n}`);
  const s1 = await md5Secs('_c1'), s2 = await md5Secs('_c2');
  for (const k of SECS) chk(`  sección ${k}`, s_vivo[k] === s1[k] && s_vivo[k] === s2[k], (s_vivo[k] || 'null').slice(0, 8));
  chk('hit ≥ 3x más rápido que rebuild', t1 / Math.max(t2, 1) >= 3, `rebuild ${t1} ms → hit ${t2} ms (${(t1 / Math.max(t2, 1)).toFixed(1)}x)`);

  // 5) todas las secciones siguen presentes
  const secs = (await c.query(`select jsonb_object_keys(r->'data') k from _c2`)).rows.map(x => x.k).sort();
  chk('secciones del payload intactas (7 + _meta)', secs.length === 8, secs.join(','));

  // 6) TEST DE INVALIDACIÓN DE PRECIO
  const victima = (await c.query(`select id_producto, precio_venta from mos.productos
      where coalesce(estado,true) and coalesce(btrim(es_envasable::text),'')<>'1' and precio_venta is not null
      order by id_producto limit 1`)).rows[0];
  const nuevo = (Number(victima.precio_venta) + 7.77).toFixed(2);
  const fpAntes = (await c.query(`select mos._catalogo_pos_fp() f`)).rows[0].f;
  const vAntes = (await c.query(`select version from mos.catalogo_meta where id=1`)).rows[0].version;
  await c.query(`update mos.productos set precio_venta=$1 where id_producto=$2`, [nuevo, victima.id_producto]);
  const fpDsp = (await c.query(`select mos._catalogo_pos_fp() f`)).rows[0].f;
  const vDsp = (await c.query(`select version from mos.catalogo_meta where id=1`)).rows[0].version;
  chk('update de precio mueve el fingerprint', fpAntes !== fpDsp, `${fpAntes.slice(0, 8)} → ${fpDsp.slice(0, 8)}`);
  chk('update de precio bumpea catalogo_meta.version', String(vAntes) !== String(vDsp), `${vAntes} → ${vDsp} (best-effort: por eso NO es la clave)`);

  const [t3] = await ms(`create temp table _c3 on commit drop as select mos.catalogo_pos_rls() r`);
  const leido = (await c.query(`select (e->>'Precio_Venta')::numeric p from _c3, jsonb_array_elements(r->'data'->'PRESENTACIONES') e where e->>'SKU'=$1`, [victima.id_producto])).rows[0];
  const cc2 = (await c.query(`select version_fp, built_at, build_ms from mos.catalogo_cache where fn='catalogo_pos_rls'`)).rows[0];
  chk('tras el cambio RECONSTRUYE (no sirve viejo)', cc2.built_at.toISOString() !== b1, `built_at ${b1} → ${cc2.built_at.toISOString()} (${t3} ms)`);
  chk('el precio NUEVO llega al payload', leido && Number(leido.p) === Number(nuevo), `esperado ${nuevo} · leído ${leido ? leido.p : 'NO ENCONTRADO'} (antes ${victima.precio_venta})`);
  chk('la fila de caché quedó re-keyed al fp nuevo', cc2.version_fp === fpDsp, `${cc2.version_fp.slice(0, 8)}`);

  // 7) hit tras la reconstrucción (3 muestras: la instancia es compartida y ruidosa)
  const b3 = cc2.built_at.toISOString(); const hits = [];
  for (let i = 0; i < 3; i++) hits.push((await ms(`select length(mos.catalogo_pos_rls()::text)`))[0]);
  const cc3 = (await c.query(`select built_at from mos.catalogo_cache where fn='catalogo_pos_rls'`)).rows[0];
  chk('3 llamadas seguidas = 3 HITs (built_at intacto)', cc3.built_at.toISOString() === b3, `hits: ${hits.join(' / ')} ms`);

  // 8) sondeo: ¿vale la pena cachear productos_master_rls?
  const [tp, rp] = await ms(`select length(mos.productos_master_rls()::text) n`);
  const [tpc] = await ms(`select length(payload::text) from mos.catalogo_cache where fn='catalogo_pos_rls'`);
  console.log(`  · sondeo productos_master_rls: ${tp} ms vivo · ${rp.n} bytes | releer 1.8MB de jsonb cacheado cuesta ${tpc} ms`);
} finally {
  await c.query('rollback');
}

const okAll = T.every(x => x[0]);
console.log(`╚══ ${T.filter(x => x[0]).length}/${T.length} checks ══╝`);
if (!okAll) { console.log('\n❌ HAY CHECKS EN ROJO — NO SE APLICA NADA.'); await c.end(); process.exit(1); }

// ═══════════════════ APLICAR ═══════════════════
console.log('\n▶ aplicando…');
await c.query('begin');
await c.query(DDL_TABLA);
await c.query(DDL_FP);
const dLive = patchPos(await def('catalogo_pos_rls'));
if (dLive) { await c.query(dLive); console.log('  · catalogo_pos_rls parchada'); }
else console.log('  · catalogo_pos_rls ya estaba parchada (idempotente)');
await c.query('commit');

// warm-up + medición real en PROD (la 1ª paga el rebuild; el resto son hits)
const [w1] = await ms(`select length(mos.catalogo_pos_rls()::text)`);
const post = []; let bytes = 0;
for (let i = 0; i < 5; i++) { const [t, r] = await ms(`select length(mos.catalogo_pos_rls()::text) n`); post.push(t); bytes = r.n; }
const fila = (await c.query(`select version, left(version_fp,12) fp, build_ms, built_at from mos.catalogo_cache`)).rows;
console.log(`\n✅ 650 aplicado`);
console.log(`   PROD · 1ª (rebuild) ${w1} ms · hits: ${post.join(' / ')} ms · ${bytes} bytes`);
console.log(`   caché: ${JSON.stringify(fila)}`);
await c.end();
