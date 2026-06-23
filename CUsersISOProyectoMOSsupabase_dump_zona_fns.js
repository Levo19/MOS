const fs=require('fs');const {Client}=require('pg');
const url=fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim();
(async()=>{
const c=new Client({connectionString:url,ssl:{rejectUnauthorized:false}});
await c.connect();
for(const fn of ['me.zona_ticket_dia','me.zona_lista_compras']){
  const [sch,nm]=fn.split('.');
  const r=await c.query(`select pg_get_functiondef(p.oid) def from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname=$1 and p.proname=$2`,[sch,nm]);
  console.log('===== '+fn+' ('+r.rows.length+' overloads) =====');
  r.rows.forEach(row=>console.log(row.def+'\n\n'));
}
await c.end();
})().catch(e=>{console.error('ERR',e.message);process.exit(1);});
