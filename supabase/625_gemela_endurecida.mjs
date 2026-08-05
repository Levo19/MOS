// 625 · wh.vencer_listas_sombra: endurece la detección de "guía gemela" [604b] y deja
// de cerrar sombras con guías PARCIALES en silencio.
//
// La heurística decide si la mercadería escaneada ya salió en una guía real (→ no crea
// guía) o no (→ crea GLSC_ y descuenta stock). Equivocarse descuenta dos veces o no
// descuenta nada. Hoy no hay daño histórico (la rama sólo existe desde el 01/08 y aún
// no le tocó ningún caso), pero la regla tiene agujeros que se abren con el tiempo:
//
//  1. La ventana de fecha no tenía TOPE SUPERIOR: `fecha >= creación − 1h` y nada más.
//     Cuanto más pasa el tiempo, más guías futuras caen dentro y más falsos positivos.
//  2. Emparejaba con guías ANULADAS (que no descontaron) → el descuento se perdía.
//  3. Podía emparejar con una GLSC_ creada por otra sombra (auto-referencia).
//  4. Con varias candidatas tomaba la primera, sin registrar la ambigüedad.
//  5. NUEVO Y REAL: si un skuBase no resuelve su canónico con código de barra, esa línea
//     se cae de la guía sin avisar. Hoy 66 de 183 líneas escaneadas están así: se habría
//     emitido una guía PARCIAL y la sombra quedaría cerrada como si todo hubiera salido.
//
// Criterio ante la duda: NO crear guía (un descuento de más deja stock negativo, que es
// el daño caro) y dejar constancia en wh.ops_log para revisión humana.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

let def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='wh' and p.proname='vencer_listas_sombra' and p.prokind='f'`)).rows[0].d;

const rep = (from, to, etiqueta) => {
  const n = def.split(from).length - 1;
  if (n !== 1) throw new Error(`[${etiqueta}] esperaba 1 coincidencia, hay ${n}`);
  def = def.replace(from, to);
};

rep(`  v_esc numeric; v_esc_items int; v_det jsonb; v_res jsonb; v_guia text; v_twin text;`,
    `  v_esc numeric; v_esc_items int; v_det jsonb; v_res jsonb; v_guia text; v_twin text;
  v_cand int := 0;      -- [625] cuántas guías compiten por ser la gemela
  v_faltan int := 0;    -- [625] líneas escaneadas que no resuelven su código de barra
  v_nota_extra text := '';`,
    'declare');

// 1) búsqueda de gemela endurecida + conteo de candidatas
rep(`      select g.id_guia into v_twin
        from wh.guias g
       where upper(coalesce(g.id_zona,'')) = upper(coalesce(v_row.zona,''))
         and g.tipo like 'SALIDA%'
         and g.fecha >= v_row.fecha_creacion - interval '1 hour'
         and abs(coalesce((select sum(gd.cant_recibida) from wh.guia_detalle gd where gd.id_guia = g.id_guia), 0) - v_esc) < 0.01
         and abs(coalesce((select count(*) from wh.guia_detalle gd where gd.id_guia = g.id_guia), 0) - v_esc_items) <= 2
       order by g.fecha limit 1;`,
    `      -- [625] ventana ACOTADA por arriba (antes sólo tenía piso: cualquier guía futura
      -- casaba), sin anuladas (no descontaron) y sin las GLSC_ de otras sombras.
      select count(*), min(g.id_guia) into v_cand, v_twin
        from wh.guias g
       where upper(coalesce(g.id_zona,'')) = upper(coalesce(v_row.zona,''))
         and g.tipo like 'SALIDA%'
         and g.fecha >= v_row.fecha_creacion - interval '1 hour'
         and g.fecha <= v_row.fecha_creacion + interval '26 hours'
         and upper(coalesce(g.estado,'')) <> 'ANULADA'
         and g.id_guia not like 'GLSC\\_%'
         and abs(coalesce((select sum(gd.cant_recibida) from wh.guia_detalle gd where gd.id_guia = g.id_guia), 0) - v_esc) < 0.01
         and abs(coalesce((select count(*) from wh.guia_detalle gd where gd.id_guia = g.id_guia), 0) - v_esc_items) <= 2;
      if v_cand = 0 then v_twin := null; end if;`,
    'gemela');

// 2) detectar líneas escaneadas que NO resuelven su código de barra
rep(`      if v_twin is not null then
        v_det := '[]'::jsonb;   -- gemela detectada → sin guía nueva (solo contabilidad)
      end if;`,
    `      -- [625] líneas escaneadas que se caerían de la guía por no resolver su canónico.
      -- Emitir la guía igual dejaría un descuento PARCIAL con la sombra cerrada como
      -- completa: preferimos no emitir y que quede constancia para revisión.
      select count(*) into v_faltan
        from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) it
       where wh._num(coalesce(it->>'cantidadEscaneada','0')) > 0
         and coalesce(btrim(it->>'skuBase'),'') <> ''
         and not exists (select 1 from mos.productos p
                          where p.sku_base = it->>'skuBase'
                            and coalesce(btrim(p.codigo_producto_base),'') = ''
                            and coalesce(p.factor_conversion, 1) = 1
                            and coalesce(btrim(p.codigo_barra),'') <> '');

      if v_twin is not null then
        v_det := '[]'::jsonb;   -- gemela detectada → sin guía nueva (solo contabilidad)
        if v_cand > 1 then
          v_nota_extra := v_nota_extra || ' · AMBIGUO: ' || v_cand || ' guías posibles, no se emitió guía (revisar)';
          begin
            insert into wh.ops_log (id_op, id_guia, tipo, payload, estado, usuario, fecha_creado, error)
            values ('GEM-AMB-'||v_row.id_lista||'-'||(extract(epoch from now())*1000)::bigint,
                    v_row.id_lista, 'SOMBRA_GEMELA_AMBIGUA',
                    jsonb_build_object('idLista',v_row.id_lista,'zona',v_row.zona,'candidatas',v_cand,
                                       'elegida',v_twin,'uds',v_esc),
                    'REVISAR', coalesce(v_row.usuario_tomada, v_row.usuario_creador,'sistema'), now(),
                    v_cand||' guías compiten como gemela; no se emitió guía para no descontar dos veces');
          exception when others then null; end;
        end if;
      elsif v_faltan > 0 then
        v_det := '[]'::jsonb;   -- guía saldría incompleta → no emitir
        v_nota_extra := v_nota_extra || ' · ' || v_faltan || ' líneas sin código de barra: NO se emitió guía (descuento pendiente)';
        begin
          insert into wh.ops_log (id_op, id_guia, tipo, payload, estado, usuario, fecha_creado, error)
          values ('GEM-PARC-'||v_row.id_lista||'-'||(extract(epoch from now())*1000)::bigint,
                  v_row.id_lista, 'SOMBRA_GUIA_PARCIAL',
                  jsonb_build_object('idLista',v_row.id_lista,'zona',v_row.zona,'lineasSinCodigo',v_faltan,'uds',v_esc),
                  'REVISAR', coalesce(v_row.usuario_tomada, v_row.usuario_creador,'sistema'), now(),
                  v_faltan||' líneas escaneadas no resuelven código de barra: la guía habría descontado de menos');
        exception when others then null; end;
      end if;`,
    'parcial');

// 3) que la nota cuente lo que pasó
rep(`                         else '' end || ']'`,
    `                         else '' end || v_nota_extra || ']'`,
    'nota');

// ── verificación
await c.query('begin');
await c.query(def);
const t = []; const chk = (n, cond) => { t.push([cond ? '✅' : '❌', n]); return cond; };
const nueva = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and p.proname='vencer_listas_sombra'`)).rows[0].d;

chk('la ventana de gemela ya tiene tope superior', nueva.includes("+ interval '26 hours'"));
chk('no empareja con guías anuladas', /upper\(coalesce\(g\.estado,''\)\) <> 'ANULADA'/.test(nueva));
chk('no empareja con las GLSC_ de otras sombras', nueva.includes("g.id_guia not like 'GLSC\\_%'"));
chk('cuenta candidatas en vez de tomar la primera a ciegas', nueva.includes('into v_cand, v_twin'));
chk('registra la ambigüedad', nueva.includes('SOMBRA_GEMELA_AMBIGUA'));
chk('detecta líneas sin código de barra', nueva.includes('SOMBRA_GUIA_PARCIAL'));
chk('la nota de la sombra explica por qué no hubo guía', nueva.includes('v_nota_extra || \']\''));

// no rompe lo que ya funcionaba
chk('sigue liberando el candado a los 30 min [605]', nueva.includes('candado liberado'));
chk('sigue avisando del pre-vencimiento', nueva.includes('[aviso-ttl]'));
chk('sigue anulando las vencidas sin escaneo', nueva.includes('24h sin despachar'));
chk('sigue llamando al cierre contable', nueva.includes('wh.cerrar_lista_sombra'));
chk('si la guía falla sigue reintentando el próximo ciclo', nueva.includes('continue;'));

// corre de verdad sobre producción (en tx) y no explota
let r = null;
try { r = (await c.query(`select wh.vencer_listas_sombra() r`)).rows[0].r; } catch (e) { r = { err: e.message }; }
chk('la función corre sin error sobre los datos reales', r?.ok === true, r?.err);
chk('no anuló nada inesperado en esta corrida', r && +r.vencidasDisponibles === 0 && +r.vencidasEnUso === 0);

// caso ambiguo forzado: 2 guías idénticas compitiendo → no debe emitir guía
await c.query(`insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, zona, fecha_tomada, usuario_tomada)
  values ('LS-T625', now() - interval '30 hours', 'test',
   '[{"skuBase":"T625","nombre":"Z","cantidad":5,"cantidadEscaneada":5}]'::jsonb, 'EN_USO', 'ZONA-02',
   now() - interval '30 hours', 'test')`);
for (const g of ['G-T625-A', 'G-T625-B']) {
  await c.query(`insert into wh.guias (id_guia, tipo, id_zona, fecha, estado) values ($1,'SALIDA_ZONA','ZONA-02', now() - interval '29 hours','ACTIVA')`, [g]);
  await c.query(`insert into wh.guia_detalle (id_guia, linea, cod_producto, cant_recibida) values ($1,1,'X625',5)`, [g]);
}
await c.query(`select wh.vencer_listas_sombra()`);
const amb = (await c.query(`select count(*) n from wh.ops_log where tipo='SOMBRA_GEMELA_AMBIGUA' and id_guia='LS-T625'`)).rows[0].n;
chk('con 2 guías candidatas registra la ambigüedad y no inventa una guía', +amb === 1, `ops_log=${amb}`);
chk('no creó GLSC_ para el caso ambiguo',
    (await c.query(`select count(*) n from wh.guias where id_guia='GLSC_LS-T625'`)).rows[0].n === '0');

t.forEach(([s, n, x]) => console.log(' ', s, n, x ? '· ' + String(x).slice(0, 90) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }

await c.query(def);
console.log(`\n✅ ${t.length}/${t.length} — 625 aplicado a la definición viva`);
fs.writeFileSync('625_gemela_endurecida.sql', def);
await c.end();
