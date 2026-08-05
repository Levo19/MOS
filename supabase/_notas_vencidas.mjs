import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── qué dejó escrito el vencedor en las sombras escaneadas:');
console.table((await c.query(`
  select ls.id_lista, ls.zona, upper(ls.estado) estado,
    (select coalesce(sum(wh._num(coalesce(it->>'cantidadEscaneada','0'))),0)
       from jsonb_array_elements(coalesce(ls.items,'[]'::jsonb)) it)::numeric(10,2) escaneado,
    left(coalesce(ls.nota,''),150) nota
    from wh.listas_sombra ls
   where coalesce(btrim(ls.zona),'')<>''
     and (select coalesce(sum(wh._num(coalesce(it->>'cantidadEscaneada','0'))),0)
            from jsonb_array_elements(coalesce(ls.items,'[]'::jsonb)) it) > 0
   order by ls.fecha_creacion desc`)).rows);

console.log('\n── ¿los skuBase escaneados encuentran su canónico con código de barra?');
console.table((await c.query(`
  with it as (select ls.id_lista, jsonb_array_elements(coalesce(ls.items,'[]'::jsonb)) i
                from wh.listas_sombra ls where coalesce(btrim(ls.zona),'')<>'')
  select count(*) filter (where esc>0) lineas_escaneadas,
         count(*) filter (where esc>0 and cb is null) sin_canonico_ni_codigo
    from (select it.id_lista, wh._num(coalesce(i->>'cantidadEscaneada','0')) esc,
            (select p.codigo_barra from mos.productos p
              where p.sku_base = i->>'skuBase' and coalesce(btrim(p.codigo_producto_base),'')=''
                and coalesce(p.factor_conversion,1)=1 and coalesce(btrim(p.codigo_barra),'')<>''
              order by p.id_producto limit 1) cb
           from it) x`)).rows);
await c.end();
