// ¿Cuánto se equivoca la heurística de guía gemela [604b]?
// Regla actual: misma zona · fecha >= creación−1h (SIN tope) · total ±0.01 · ±2 líneas · limit 1
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

console.log('── guías que la sombra creó por su cuenta (GLSC_) = casos donde NO halló gemela');
console.table((await c.query(`
  select to_char(g.fecha at time zone 'America/Lima','YYYY-MM') mes, g.id_zona, count(*) guias,
         sum((select coalesce(sum(gd.cant_recibida),0) from wh.guia_detalle gd where gd.id_guia=g.id_guia))::numeric(12,2) unidades
    from wh.guias g where g.id_guia like 'GLSC\\_%' group by 1,2 order by 1 desc,2`)).rows);

// Para cada sombra vencida, ¿cuántas candidatas da la regla ACTUAL vs la ENDURECIDA?
const q = (extra) => `
  with s as (
    select ls.id_lista, ls.zona, ls.fecha_creacion,
           (select coalesce(sum(wh._num(coalesce(it->>'cantidadEscaneada','0'))),0)
              from jsonb_array_elements(coalesce(ls.items,'[]'::jsonb)) it) esc,
           (select count(*) from jsonb_array_elements(coalesce(ls.items,'[]'::jsonb)) it
             where wh._num(coalesce(it->>'cantidadEscaneada','0'))>0) esc_items
      from wh.listas_sombra ls
     where coalesce(btrim(ls.zona),'') <> ''
  )
  select s.id_lista, s.zona, s.esc,
         (select count(*) from wh.guias g
           where upper(coalesce(g.id_zona,''))=upper(coalesce(s.zona,''))
             and g.tipo like 'SALIDA%'
             and g.fecha >= s.fecha_creacion - interval '1 hour'
             ${extra}
             and abs(coalesce((select sum(gd.cant_recibida) from wh.guia_detalle gd where gd.id_guia=g.id_guia),0) - s.esc) < 0.01
             and abs(coalesce((select count(*) from wh.guia_detalle gd where gd.id_guia=g.id_guia),0) - s.esc_items) <= 2
         ) candidatas
    from s where s.esc > 0`;

const act = (await c.query(q(''))).rows;
const end = (await c.query(q(`and g.fecha <= s.fecha_creacion + interval '26 hours'
             and upper(coalesce(g.estado,'')) <> 'ANULADA'
             and g.id_guia not like 'GLSC\\_%'`))).rows;

const resum = (rows, etiq) => {
  const cero = rows.filter(r => +r.candidatas === 0).length;
  const una = rows.filter(r => +r.candidatas === 1).length;
  const varias = rows.filter(r => +r.candidatas > 1).length;
  const udsCero = rows.filter(r => +r.candidatas === 0).reduce((a, r) => a + (+r.esc), 0);
  console.log(`  ${etiq}: ${rows.length} sombras · sin gemela ${cero} (${udsCero.toFixed(1)} uds → crea guía) · gemela única ${una} · AMBIGUAS ${varias}`);
  return { cero, una, varias };
};
console.log('\n── candidatas por sombra escaneada');
const A = resum(act, 'regla ACTUAL   ');
const B = resum(end, 'regla ENDURECIDA');

console.log('\n── sombras donde las dos reglas DISCREPAN (ahí está el daño)');
const mapB = new Map(end.map(r => [r.id_lista, +r.candidatas]));
const dif = act.filter(r => (+r.candidatas > 0) !== ((mapB.get(r.id_lista) || 0) > 0));
console.table(dif.slice(0, 15).map(r => ({ lista: r.id_lista, zona: r.zona, uds: r.esc,
  actual: +r.candidatas, endurecida: mapB.get(r.id_lista) ?? 0,
  efecto: +r.candidatas > 0 ? 'ACTUAL la da por gemela y NO descuenta (stock queda alto)' : 'ACTUAL crea guía → riesgo doble descuento' })));
console.log(`discrepan ${dif.length} de ${act.length} sombras`);

console.log('\n── ¿una misma guía es "gemela" de varias sombras a la vez? (imposible en la realidad)');
console.table((await c.query(`
  with s as (
    select ls.id_lista, ls.zona, ls.fecha_creacion,
           (select coalesce(sum(wh._num(coalesce(it->>'cantidadEscaneada','0'))),0)
              from jsonb_array_elements(coalesce(ls.items,'[]'::jsonb)) it) esc,
           (select count(*) from jsonb_array_elements(coalesce(ls.items,'[]'::jsonb)) it
             where wh._num(coalesce(it->>'cantidadEscaneada','0'))>0) esc_items
      from wh.listas_sombra ls where coalesce(btrim(ls.zona),'') <> '')
  select twin, count(*) sombras_que_la_reclaman, string_agg(id_lista, ', ') listas from (
    select s.id_lista, (select g.id_guia from wh.guias g
       where upper(coalesce(g.id_zona,''))=upper(coalesce(s.zona,'')) and g.tipo like 'SALIDA%'
         and g.fecha >= s.fecha_creacion - interval '1 hour'
         and abs(coalesce((select sum(gd.cant_recibida) from wh.guia_detalle gd where gd.id_guia=g.id_guia),0) - s.esc) < 0.01
         and abs(coalesce((select count(*) from wh.guia_detalle gd where gd.id_guia=g.id_guia),0) - s.esc_items) <= 2
       order by g.fecha limit 1) twin
      from s where s.esc > 0) x
   where twin is not null group by twin having count(*) > 1 order by 2 desc limit 10`)).rows);
await c.end();
