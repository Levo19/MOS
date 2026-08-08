#!/bin/bash
# Vigila la cola de sustitutos; al vaciarse (o estancarse 3 chequeos) restaura cron */10 y reporta.
cd "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase"
prev=-1; estancado=0
for i in $(seq 1 40); do
  sleep 300
  n=$(node -e "
    const fs=require('fs');const {Client}=require('pg');
    const c=new Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(),ssl:{rejectUnauthorized:false}});
    c.connect().then(async()=>{
      const r=await c.query(\"select count(*)::int n from mos.productos where tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(estado,true) and (sustitutos_internos is null or coalesce(sust_stale,false))\");
      console.log(r.rows[0].n); await c.end();
    }).catch(e=>{console.log('-1')});" 2>/dev/null)
  echo "[watch] chequeo $i: faltan $n"
  if [ "$n" = "0" ]; then echo "[watch] COLA VACÍA ✅"; break; fi
  if [ "$n" = "$prev" ]; then estancado=$((estancado+1)); else estancado=0; fi
  if [ $estancado -ge 3 ]; then echo "[watch] ESTANCADO en $n (¿crédito agotado de nuevo?)"; break; fi
  prev=$n
done
node _sust_cron.mjs 2>/dev/null && echo "[watch] cron restaurado a */10"
node _sust_pend_count.mjs 2>/dev/null
