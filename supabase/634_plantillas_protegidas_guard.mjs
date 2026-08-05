// 634 · adhesivo_plantilla_eliminar: candado REAL para las plantillas de sistema.
// Decisión del dueño: las creaciones humanas del Estudio SÍ se borran; las fabricadas
// por encargo (metadata.protegida=true) NO — y no basta ocultar el botón: el server
// rechaza aunque alguien llame a la RPC a mano.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

let def = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='mos' and p.proname='adhesivo_plantilla_eliminar' and p.prokind='f'`)).rows[0].d;
console.log('── def actual (' + def.split('\n').length + ' líneas):');
console.log(def);

// insertar el guard justo después del begin (patrón genérico y verificable)
const i = def.indexOf('begin');
if (i < 0) throw new Error('sin begin');
const guard = `begin
  -- [634] PLANTILLA DE SISTEMA: metadata.protegida=true → NO se elimina jamás
  -- (las fabrica Claude por encargo del dueño; las del Estudio sí son borrables).
  if exists (select 1 from mos.adhesivo_plantillas ap
              where ap.id_plantilla = btrim(coalesce(p->>'idPlantilla',''))
                and coalesce((ap.json->'metadata'->>'protegida')::boolean, false) = true) then
    return jsonb_build_object('ok', false, 'error', 'PLANTILLA_PROTEGIDA: es de sistema, no se puede eliminar');
  end if;
`;
def = def.slice(0, i) + guard + def.slice(i + 'begin'.length);

await c.query('begin');
await c.query(def);
const t = []; const chk = (n, cond, x) => { t.push([cond ? '✅' : '❌', n, x]); return cond; };

// protegida → rechazada
const r1 = (await c.query(`select mos.adhesivo_plantilla_eliminar($1::jsonb) r`,
  [JSON.stringify({ idPlantilla: 'ADH-PAPITO-01' })])).rows[0].r;
chk('una protegida (Dulce Níspero) se RECHAZA', r1.ok === false && /PROTEGIDA/.test(r1.error || ''), JSON.stringify(r1));
chk('y sigue existiendo', (await c.query(`select count(*) n from mos.adhesivo_plantillas where id_plantilla='ADH-PAPITO-01'`)).rows[0].n === '1');

// una propia (sin protegida) → se elimina
await c.query(`insert into mos.adhesivo_plantillas (id_plantilla, nombre, descripcion, tamano_canvas, json, creado_por, fecha_creado, fecha_ult_mod, activo)
  values ('ADH-T634', 'PRUEBA PROPIA', 'test', '50x25', '{"capas":[],"metadata":{"nombre":"t"}}'::jsonb, 'test', now(), now(), true)`);
const r2 = (await c.query(`select mos.adhesivo_plantilla_eliminar($1::jsonb) r`,
  [JSON.stringify({ idPlantilla: 'ADH-T634' })])).rows[0].r;
chk('una creación propia SÍ se elimina', r2.ok !== false, JSON.stringify(r2).slice(0, 80));

t.forEach(([s, n, x]) => console.log(' ', s, n, x !== undefined ? '· ' + String(x).slice(0, 100) : ''));
const fallos = t.filter(x => x[0] === '❌').length;
await c.query('rollback');
if (fallos) { console.log(`\n❌ ${fallos} fallaron — NO se aplica`); await c.end(); process.exit(1); }
await c.query(def);
console.log(`\n✅ ${t.length}/${t.length} — 634 aplicado`);
fs.writeFileSync('634_plantillas_protegidas_guard.sql', def);
await c.end();
