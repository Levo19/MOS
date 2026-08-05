// 624 · wh.cerrar_lista_sombra: el acumulado ya no falla en silencio.
//
// Contexto: el bloque [540] que traslada "pedido − despachado" a la deuda de la zona
// terminaba en `exception when others then null`. Si alguna vez falla, la zona pierde
// su deuda y NADIE se entera: el cierre devuelve ok:true igual.
//
// Criterio: el cierre de la lista NO debe romperse por esto (el operador ya despachó
// físicamente; abortar el cierre sería peor). Pero el error tiene que quedar registrado
// en wh.ops_log y viajar en la respuesta para que el frontend pueda avisar.
//
// Se parchea la definición VIVA (pg_get_functiondef), no el .sql del repo.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

let def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='wh' and p.proname='cerrar_lista_sombra' and p.prokind='f'`)).rows[0].d;

const rep = (from, to, etiqueta) => {
  const n = def.split(from).length - 1;
  if (n !== 1) throw new Error(`[${etiqueta}] esperaba 1 coincidencia, hay ${n}`);
  def = def.replace(from, to);
};

// 1) variables nuevas
rep(`  v_now  timestamptz := now();`,
    `  v_now  timestamptz := now();
  v_acum text := 'sin_faltante';   -- [624] sin_faltante | creado | error
  v_err  text;`,
    'declare');

// 2) marcar el éxito del insert
rep(`        on conflict (id_pickup) do nothing;
      end if;`,
    `        on conflict (id_pickup) do nothing;
        v_acum := 'creado';
      end if;`,
    'exito');

// 3) el corazón: dejar de tragarse el error
rep(`    exception when others then null;
    end;`,
    `    exception when others then
      -- [624] NO abortamos el cierre (la mercadería ya salió), pero el error queda
      -- registrado y viaja en la respuesta. Antes esto era \`null\` y la deuda de la
      -- zona se perdía sin dejar rastro.
      v_acum := 'error';
      v_err  := coalesce(SQLERRM,'?')||' ('||coalesce(SQLSTATE,'?')||')';
      begin
        insert into wh.ops_log (id_op, id_guia, tipo, payload, estado, usuario, fecha_creado, error)
        values ('LSCACUM-'||v_id||'-'||(extract(epoch from v_now)*1000)::bigint,
                v_id, 'LSC_ACUMULADO_FALLO',
                jsonb_build_object('idLista', v_id, 'zona', btrim(v_row.zona),
                                   'items', jsonb_array_length(coalesce(v_pick,'[]'::jsonb))),
                'ERROR', coalesce(v_row.usuario_tomada, v_row.usuario_creador, 'sistema'),
                v_now, v_err);
      exception when others then null;  -- el log jamás puede tumbar el cierre
      end;
    end;`,
    'captura');

// 4) devolver el estado del acumulado
rep(`  return jsonb_build_object('ok',true);`,
    `  return jsonb_build_object('ok',true,'acumulado',v_acum,'acumuladoError',v_err);`,
    'return');

// ── verificación en tx antes de soltarlo
await c.query('begin');
await c.query(def);
const t = [];
const chk = (n, cond) => { t.push([cond ? '✅' : '❌', n]); return cond; };

const nueva = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='wh' and p.proname='cerrar_lista_sombra' and p.prokind='f'`)).rows[0].d;
chk('ya no queda el `exception when others then null` del acumulado',
    !/exception when others then null;\s*\n\s*end;\s*\n\s*end if;\s*\n\s*return/.test(nueva));
chk('registra el fallo en wh.ops_log', nueva.includes('LSC_ACUMULADO_FALLO'));
chk('la respuesta lleva el estado del acumulado', nueva.includes("'acumulado',v_acum"));
chk('el log no puede tumbar el cierre (exception propio)',
    nueva.includes('-- el log jamás puede tumbar el cierre'));

// camino feliz: una sombra real de mentira, cerrada, debe crear su acumulado
await c.query(`insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, zona)
  values ('LS-T624', now(), 'test', '[{"skuBase":"T624A","nombre":"X","cantidad":10,"cantidadEscaneada":4}]'::jsonb, 'PENDIENTE', 'ZONA-02')`);
const okCfg = (await c.query(`select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO'`)).rows[0]?.valor;
if (okCfg !== '1') await c.query(`insert into mos.config(clave,valor) values('WH_LISTA_SOMBRA_DIRECTO','1')
  on conflict (clave) do update set valor='1'`);
let r = null;
try { r = (await c.query(`select wh.cerrar_lista_sombra('{"idLista":"LS-T624"}'::jsonb) r`)).rows[0].r; } catch (e) { r = { err: e.message }; }
chk('cierre normal sigue devolviendo ok', r?.ok === true);
chk("informa que el acumulado se creó (acumulado='creado')", r?.acumulado === 'creado');
chk('el acumulado existe de verdad en wh.pickups',
    (await c.query(`select count(*) n from wh.pickups where id_pickup='PCK-LSC-LS-T624'`)).rows[0].n === '1');
chk('sin fallo, no ensucia el log',
    (await c.query(`select count(*) n from wh.ops_log where tipo='LSC_ACUMULADO_FALLO'`)).rows[0].n === '0');

// camino de fallo FORZADO: rompemos el insert para comprobar que ahora sí deja rastro
await c.query(`insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, zona)
  values ('LS-T624B', now(), 'test', '[{"skuBase":"T624B","nombre":"Y","cantidad":9,"cantidadEscaneada":1}]'::jsonb, 'PENDIENTE', 'ZONA-02')`);
await c.query(`create or replace function wh._boom_624() returns trigger language plpgsql as
  $$ begin raise exception 'fallo simulado del acumulado'; end; $$`);
await c.query(`create trigger _t_boom_624 before insert on wh.pickups for each row
  when (new.id_pickup = 'PCK-LSC-LS-T624B') execute function wh._boom_624()`);
let r2 = null;
try { r2 = (await c.query(`select wh.cerrar_lista_sombra('{"idLista":"LS-T624B"}'::jsonb) r`)).rows[0].r; } catch (e) { r2 = { err: e.message }; }
chk('con el acumulado roto, el CIERRE igual se completa (la mercadería ya salió)', r2?.ok === true);
chk("avisa del fallo (acumulado='error')", r2?.acumulado === 'error');
chk('el mensaje real del error viaja en la respuesta',
    typeof r2?.acumuladoError === 'string' && /fallo simulado/.test(r2.acumuladoError));
chk('la lista quedó COMPLETADA pese al fallo',
    (await c.query(`select estado from wh.listas_sombra where id_lista='LS-T624B'`)).rows[0].estado === 'COMPLETADA');
const log = (await c.query(`select id_guia, tipo, estado, error from wh.ops_log where tipo='LSC_ACUMULADO_FALLO'`)).rows;
chk('quedó registrado en wh.ops_log (antes desaparecía sin rastro)', log.length === 1 && log[0].id_guia === 'LS-T624B');
chk('el log guarda el error legible', /fallo simulado/.test(log[0]?.error || ''));

t.forEach(([s, n]) => console.log(' ', s, n));
const fallos = t.filter(x => x[0] === '❌').length;
if (fallos) { await c.query('rollback'); console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }
await c.query('rollback');

// aplicar de verdad (solo la función; nada de los datos de prueba)
await c.query(def);
console.log(`\n✅ ${t.length}/${t.length} — 624 aplicado a la definición viva`);
fs.writeFileSync('624_sombra_acumulado_no_silencioso.sql', def);
await c.end();
