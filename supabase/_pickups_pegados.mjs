import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── estados de pickups (60 días)');
console.table((await c.query(`select estado, fuente, count(*) n,
   to_char(min(fecha_creado) at time zone 'America/Lima','DD/MM') mas_viejo,
   to_char(max(fecha_creado) at time zone 'America/Lima','DD/MM') mas_nuevo
   from wh.pickups where fecha_creado >= now() - interval '60 days' group by 1,2 order by 3 desc`)).rows);

console.log('\n── PICKUPS ABIERTOS con más de 12 horas (los "pegados")');
console.table((await c.query(`
  select id_pickup, estado, id_zona, left(coalesce(creado_por,''),14) creado_por,
         jsonb_array_length(coalesce(items,'[]'::jsonb)) items,
         to_char(fecha_creado at time zone 'America/Lima','DD/MM HH24:MI') creado,
         to_char(ultima_actividad at time zone 'America/Lima','DD/MM HH24:MI') ult_act,
         round(extract(epoch from (now()-fecha_creado))/3600)::int horas
    from wh.pickups
   where upper(coalesce(estado,'')) not in ('ABSORBIDO','CERRADO','ATENDIDO','ANULADO')
     and fecha_creado < now() - interval '12 hours'
   order by fecha_creado desc limit 15`)).rows);

console.log('\n── ¿esos pickups tienen guía de salida asociada? (o sea: SÍ se despachó)');
console.table((await c.query(`
  select p.id_pickup, p.estado,
         (select count(*) from wh.guias g where g.id_guia like 'GPCK\_'||p.id_pickup||'%'
             or g.comentario like '%'||p.id_pickup||'%') guias_asociadas
    from wh.pickups p
   where upper(coalesce(p.estado,'')) not in ('ABSORBIDO','CERRADO','ATENDIDO','ANULADO')
     and p.fecha_creado < now() - interval '12 hours'
   order by p.fecha_creado desc limit 10`)).rows);
await c.end();
