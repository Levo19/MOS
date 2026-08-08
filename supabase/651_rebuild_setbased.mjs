// 651 · INCIDENTE: el rebuild de la caché 650 (~9 s de CPU) satura la instancia y tumba
//   al resto de RPCs (productos_master_rls → HTTP 500 x5 por el timeout de 8 s del rol,
//   operacion_detalle 9.8 s, estado_bloqueo 6.6 s, catálogo del panel "0 grupos · 0 ítems").
//   Fuera de la ventana de rebuild, master_rls responde 476 ms normal ⇒ era la tormenta.
//
// CAUSA RAÍZ (medida en 650): el 94% de los ~9 s NO es leer datos — es el append cuadrático
//   `v_pb := v_pb || …` / `v_pr := v_pr || …` dentro del loop plpgsql. Cada `||` copia el
//   array entero: O(n²) sobre 1767 bases + 2244 presentaciones. Solo iterar el loop con
//   sus subqueries costaba ~200 ms; los appends, ~9 100 ms.
//
// FIX: mismo cálculo, forma SET-BASED (jsonb_agg en vez de ||). Cero cambios de lógica.
//
// ORDEN (lo delicado): el orden de PRODUCTO_BASE/PRESENTACIONES lo dictaba el orden en que
//   el `for g in` recibía los grupos, que es el orden de salida del HashAggregate — NO es
//   expresable como un `order by` de negocio. Se replica EXACTO así:
//     · la query agregada del loop se copia TAL CUAL dentro de un CTE `grp` MATERIALIZED
//       (mismo plan, mismas filas, mismo orden de salida que tenía el loop),
//     · `row_number() over ()` sobre ese CTE congela ese orden en `rn`,
//     · todos los jsonb_agg llevan `order by rn` (y `order by rn, k` para las presentaciones,
//       donde k es la ordinality de jsonb_array_elements = el orden del `for m in` interno).
//   Las subqueries por grupo (v_vend / v_f1 / v_base) se copian carácter por carácter para
//   que los desempates arbitrarios (incluido el DESEMPATE KGM de dinero) caigan igual.
//
// Intactos: firma catalogo_pos_rls() sin args, SECURITY DEFINER, search_path='',
//   statement_timeout=30s, grants, y toda la fontanería de caché de 650.
// Helpers mos._conv_tipo_igv / mos._norm_unidad_medida son IMMUTABLE ⇒ set-based es seguro.
// Test en begin/rollback + REPEATABLE READ (la BD es prod viva) ANTES de aplicar.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
await c.query(`set statement_timeout='600s'`);

const def = async () => (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='catalogo_pos_rls'`)).rows[0].d;
const T = []; const chk = (n, cond, x) => { T.push([cond, n, x]); console.log(`  ${cond ? '✅' : '❌'} ${n}${x ? ' · ' + x : ''}`); return cond; };
const ms = async (sql) => { const a = Date.now(); const r = await c.query(sql); return [Date.now() - a, r.rows[0]]; };

// ───────── bloque set-based que reemplaza al loop completo ─────────
const SETBASED = `  -- [651] CONSTRUCCIÓN SET-BASED (antes: loop plpgsql que concatenaba con el operador de
  -- append de jsonb sobre los acumuladores ⇒ copia el array entero por elemento, O(n²), ~9 s).
  -- Misma lógica exacta. El orden del loop se congela en \`rn\`: grp es MATERIALIZED con la
  -- MISMA query agregada que alimentaba el \`for g in\`, y row_number() over () captura su
  -- orden de salida (HashAggregate). Todos los agg llevan order by rn (+ k = orden del for m).
  with act as (
      select coalesce(nullif(btrim(sku_base),''), id_producto) as sku,
             id_producto, codigo_barra, descripcion, precio_venta,
             coalesce(precio_fijo, false) as precio_fijo,
         sustitutos_internos, foto_url, categoria_ia,   -- [628] presentación de granel con precio de etiqueta
             coalesce(nullif(factor_conversion,0),1) as factor,
             (coalesce(btrim(es_envasable::text),'') <> '1') as vendible,
             coalesce(es_envasable::text,'') as es_env,
             tipo_igv, unidad, unidad_medida, cod_sunat
        from mos.productos
       where coalesce(estado, true) = true          -- [b FIX] estado es BOOLEAN: excluir apagados (false), no '0'
  ),
  grp as materialized (
    select sku, jsonb_agg(to_jsonb(act) order by factor asc) as members from act group by sku
  ),
  ordn as (select sku, members, row_number() over () as rn from grp),
  gv as (
    select o.rn, o.sku, o.members,
           -- == \`select … into v_vend from jsonb_array_elements(v_members) where vendible\`
           (select coalesce(jsonb_agg(value order by (value->>'factor')::numeric asc),'[]'::jsonb)
              from jsonb_array_elements(o.members) where (value->>'vendible')::boolean) as vend
      from ordn o
  ),
  gb as (
    select gv.rn, gv.sku, gv.vend,
           -- [fix dinero] DESEMPATE KGM idéntico al del loop: en grupos unidad-mixta (KGM+NIU,
           -- ambos factor=1) preferir KGM, si no ME ignora los tramos del granel en silencio.
           (select value from jsonb_array_elements(gv.members) where (value->>'factor')::numeric = 1
             order by (upper(coalesce(value->>'unidad_medida', value->>'unidad','')) = 'KGM') desc limit 1) as f1,
           coalesce(
             (select value from jsonb_array_elements(gv.vend) where (value->>'factor')::numeric = 1
               order by (upper(coalesce(value->>'unidad_medida', value->>'unidad','')) = 'KGM') desc limit 1),
             gv.vend->0) as base,                      -- == \`if v_base is null then v_base := v_vend->0\`
           v_tramos_map -> gv.sku as tramos
      from gv
     where jsonb_array_length(gv.vend) > 0             -- == \`continue\` cuando no hay vendibles
  )
  select
    coalesce((select jsonb_agg(jsonb_build_object(
        'SKU_Base', gb.sku,
        'Nombre', case when gb.f1 is not null and not (gb.f1->>'vendible')::boolean
                        and coalesce(gb.f1->>'id_producto','') <> coalesce(gb.base->>'id_producto','')
                       then btrim(coalesce(nullif(btrim(gb.f1->>'descripcion'),''),'') || ' ' || coalesce(gb.base->>'descripcion',''))
                       else btrim(coalesce(gb.base->>'descripcion','')) end,
        'Tipo_IGV', mos._conv_tipo_igv(gb.base->>'tipo_igv'),
        'Unidad_Medida', mos._norm_unidad_medida(gb.base->>'unidad', gb.base->>'unidad_medida'),
        'Cod_SUNAT', coalesce(gb.base->>'cod_sunat',''),
        'Foto', coalesce(gb.base->>'foto_url',''),
        'Categoria', coalesce(gb.base->'categoria_ia','{}'::jsonb),
        'segmentos_precio', coalesce(gb.tramos,'[]'::jsonb))
      order by gb.rn) from gb), '[]'::jsonb),
    coalesce((select jsonb_agg(
        jsonb_build_object(
            'SKU_Base', gb.sku, 'SKU', coalesce(e.value->>'id_producto',''),
            'Cod_Barras', coalesce(nullif(btrim(e.value->>'codigo_barra'),''), e.value->>'id_producto'),
            'Empaque', coalesce(e.value->>'descripcion',''),
            'Precio_Venta', coalesce((e.value->>'precio_venta')::numeric, 0),
            'Factor', coalesce((e.value->>'factor')::numeric, 1),
            'Sustitutos', coalesce(e.value->'sustitutos_internos','[]'::jsonb),
            'Precio_Fijo', coalesce((e.value->>'precio_fijo')::boolean, false))
          -- [c] segmentos_precio SOLO en la canónica (Factor=1, lo único que ME lee) y solo si hay tramos
          || case when (e.value->>'factor')::numeric = 1 and gb.tramos is not null
                  then jsonb_build_object('segmentos_precio', gb.tramos) else '{}'::jsonb end
      order by gb.rn, e.k) from gb, lateral jsonb_array_elements(gb.vend) with ordinality as e(value, k)), '[]'::jsonb)
  into v_pb, v_pr;
`;

// El loop va desde "\\n  for g in\\n" hasta el "end;" del bloque declare + su "end loop;".
// [^] en vez de [\\s\\S]: inmune a la pérdida de backslashes en quoting.
const RE_LOOP = new RegExp('\\n  for g in\\n[^]*?\\n    end;\\n  end loop;\\n');

function patch651(d) {
  if (/\[651\]/.test(d)) return null;                       // idempotente
  if (!/\[650\] CACH/.test(d)) throw new Error('la def no tiene el caché 650 — abortar');
  if (!RE_LOOP.test(d)) throw new Error('ancla del loop no encontrada');
  const out = d.replace(RE_LOOP, '\n' + SETBASED);
  if (out === d) throw new Error('no-op');
  if (/v_pb := v_pb \|\|/.test(out) || /v_pr := v_pr \|\|/.test(out)) throw new Error('quedó un append O(n²)');
  return out;
}

const MD5 = (e) => `md5(((${e}) #- '{data,_meta,timestamp}')::text)`;
const SECS = ['PRODUCTO_BASE', 'PRESENTACIONES', 'EQUIVALENCIAS', 'ZONAS_CONFIG', 'CLIENTES_FRECUENTES', 'STOCK_ZONAS', 'PROMOCIONES'];
const md5Secs = async (t) => { const o = {}; for (const k of SECS) o[k] = (await c.query(`select md5((r->'data'->'${k}')::text) m from ${t}`)).rows[0].m; return o; };

// ═══════════ TEST ═══════════
console.log('╔══ TEST 651 (begin/rollback · repeatable read) ══╗');
await c.query('begin isolation level repeatable read');
try {
  // 0) LOOP ACTUAL. Se vacía la caché para forzar el rebuild real y medirlo.
  await c.query(`delete from mos.catalogo_cache where fn='catalogo_pos_rls'`);
  const [tLoop] = await ms(`create temp table _loop on commit drop as select mos.catalogo_pos_rls() r`);
  const bmLoop = (await c.query(`select build_ms from mos.catalogo_cache where fn='catalogo_pos_rls'`)).rows[0].build_ms;
  const mLoop = (await c.query(`select ${MD5('r')} m, length(r::text) n from _loop`)).rows[0];
  const sLoop = await md5Secs('_loop');
  console.log(`  · LOOP O(n²)  : rebuild ${tLoop} ms (build_ms ${bmLoop}) · ${mLoop.n} bytes · md5=${mLoop.m}`);

  // 1) parche set-based
  const dNew = patch651(await def());
  if (!dNew) throw new Error('ya estaba parchada — abortar test');
  fs.writeFileSync(process.env.TMPDIR ? process.env.TMPDIR + '/p651.sql' : 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/e8682971-fe93-47c3-b8de-b8dd5c509f30/scratchpad/p651.sql', dNew);
  await c.query(dNew);
  chk('parche set-based compila', true, '');

  // 2) rebuild set-based (caché vaciada otra vez)
  await c.query(`delete from mos.catalogo_cache where fn='catalogo_pos_rls'`);
  const [tSet] = await ms(`create temp table _set on commit drop as select mos.catalogo_pos_rls() r`);
  const bmSet = (await c.query(`select build_ms from mos.catalogo_cache where fn='catalogo_pos_rls'`)).rows[0].build_ms;
  const mSet = (await c.query(`select ${MD5('r')} m, length(r::text) n from _set`)).rows[0];
  const sSet = await md5Secs('_set');
  console.log(`  · SET-BASED   : rebuild ${tSet} ms (build_ms ${bmSet}) · ${mSet.n} bytes · md5=${mSet.m}`);

  // 3) MD5-DIFF INNEGOCIABLE
  chk('md5(loop) == md5(set-based)', mLoop.m === mSet.m, `${mLoop.m} vs ${mSet.m}`);
  chk('bytes idénticos', mLoop.n === mSet.n, `${mLoop.n} vs ${mSet.n}`);
  for (const k of SECS) chk(`  sección ${k}`, sLoop[k] === sSet[k], (sLoop[k] || 'null').slice(0, 8));
  // diagnóstico de ORDEN por si algún md5 cae en rojo
  if (mLoop.m !== mSet.m) {
    for (const k of ['PRODUCTO_BASE', 'PRESENTACIONES']) {
      const o = (await c.query(`select md5((select jsonb_agg(e order by e->>'SKU_Base', e->>'SKU')::text from jsonb_array_elements(r->'data'->'${k}') e)) m,
                                       jsonb_array_length(r->'data'->'${k}') n from _loop`)).rows[0];
      const p = (await c.query(`select md5((select jsonb_agg(e order by e->>'SKU_Base', e->>'SKU')::text from jsonb_array_elements(r->'data'->'${k}') e)) m,
                                       jsonb_array_length(r->'data'->'${k}') n from _set`)).rows[0];
      console.log(`     DIAG ${k}: n ${o.n} vs ${p.n} | ordenado-por-SKU ${o.m === p.m ? 'IGUAL ⇒ SOLO ES ORDEN' : 'DISTINTO ⇒ el CONTENIDO cambió'}`);
    }
  }
  chk('build_ms bajó ≥ 5x', bmLoop / Math.max(bmSet, 1) >= 5, `${bmLoop} ms → ${bmSet} ms (${(bmLoop / Math.max(bmSet, 1)).toFixed(1)}x)`);
  chk('rebuild set-based < 2 s (no satura la instancia)', bmSet < 2000, `${bmSet} ms`);

  // 4) el hit de 650 sigue funcionando
  const bA = (await c.query(`select built_at from mos.catalogo_cache`)).rows[0].built_at.toISOString();
  const [tHit] = await ms(`select length(mos.catalogo_pos_rls()::text)`);
  const bB = (await c.query(`select built_at from mos.catalogo_cache`)).rows[0].built_at.toISOString();
  chk('caché 650 intacta: 2ª llamada es HIT', bA === bB, `${tHit} ms`);

  // 5) INVALIDACIÓN DE PRECIO
  const v = (await c.query(`select id_producto, precio_venta from mos.productos
      where coalesce(estado,true) and coalesce(btrim(es_envasable::text),'')<>'1' and precio_venta is not null
      order by id_producto limit 1`)).rows[0];
  const nuevo = (Number(v.precio_venta) + 7.77).toFixed(2);
  await c.query(`update mos.productos set precio_venta=$1 where id_producto=$2`, [nuevo, v.id_producto]);
  const [tInv] = await ms(`create temp table _inv on commit drop as select mos.catalogo_pos_rls() r`);
  const cc = (await c.query(`select built_at, build_ms from mos.catalogo_cache`)).rows[0];
  const leido = (await c.query(`select (e->>'Precio_Venta')::numeric p from _inv, jsonb_array_elements(r->'data'->'PRESENTACIONES') e where e->>'SKU'=$1`, [v.id_producto])).rows[0];
  chk('cambio de precio ⇒ RECONSTRUYE', cc.built_at.toISOString() !== bB, `${tInv} ms · build_ms ${cc.build_ms}`);
  chk('el precio NUEVO llega al payload', leido && Number(leido.p) === Number(nuevo), `esperado ${nuevo} · leído ${leido ? leido.p : 'NO ENCONTRADO'} (antes ${v.precio_venta})`);
} finally {
  await c.query('rollback');
}

if (!T.every(x => x[0])) { console.log(`╚══ ${T.filter(x => x[0]).length}/${T.length} ══╝\n❌ CHECKS EN ROJO — NO SE APLICA NADA.`); await c.end(); process.exit(1); }
console.log(`╚══ ${T.length}/${T.length} checks ══╝`);

// ═══════════ APLICAR ═══════════
console.log('\n▶ aplicando…');
await c.query('begin');
const dLive = patch651(await def());
if (dLive) { await c.query(dLive); console.log('  · catalogo_pos_rls → set-based'); } else console.log('  · ya estaba parchada (idempotente)');
await c.query('commit');

// rebuild REAL forzado: tocar un producto de prueba y revertir
console.log('\n▶ forzando un rebuild real en PROD (toca precio y revierte)…');
const vic = (await c.query(`select id_producto, precio_venta from mos.productos
   where coalesce(estado,true) and coalesce(btrim(es_envasable::text),'')<>'1' and precio_venta is not null
   order by id_producto limit 1`)).rows[0];
const orig = vic.precio_venta;
await c.query(`update mos.productos set precio_venta = precio_venta + 0.01 where id_producto=$1`, [vic.id_producto]);
const [tR1] = await ms(`select length(mos.catalogo_pos_rls()::text)`);
const r1 = (await c.query(`select build_ms from mos.catalogo_cache`)).rows[0].build_ms;
await c.query(`update mos.productos set precio_venta = $1 where id_producto=$2`, [orig, vic.id_producto]);   // revertir
const [tR2] = await ms(`select length(mos.catalogo_pos_rls()::text)`);
const r2 = (await c.query(`select build_ms from mos.catalogo_cache`)).rows[0].build_ms;
const chkP = (await c.query(`select precio_venta from mos.productos where id_producto=$1`, [vic.id_producto])).rows[0].precio_venta;
console.log(`  · rebuild #1 (precio +0.01): ${tR1} ms pared · build_ms=${r1}`);
console.log(`  · rebuild #2 (revertido)   : ${tR2} ms pared · build_ms=${r2}`);
console.log(`  · precio de ${vic.id_producto} restaurado: ${orig} → ${chkP}  ${String(orig) === String(chkP) ? '✅' : '❌ REVISAR'}`);

const hits = []; for (let i = 0; i < 6; i++) hits.push((await ms(`select length(mos.catalogo_pos_rls()::text)`))[0]);
const fin = (await c.query(`select version, left(version_fp,10) fp, build_ms, built_at from mos.catalogo_cache`)).rows[0];
console.log(`\n✅ 651 aplicado`);
console.log(`   rebuild: ~8912 ms (loop O(n²)) → ${fin.build_ms} ms (set-based)`);
console.log(`   hits: ${hits.join(' / ')} ms  (RTT base ≈106 ms)`);
console.log(`   caché: ${JSON.stringify(fin)}`);
await c.end();
