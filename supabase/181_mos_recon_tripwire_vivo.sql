-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- 181 · TRIPWIRE VIVO vs HISTÓRICO  (diagnóstico SOLO-LECTURA · app de DINERO en PROD)
-- ----------------------------------------------------------------------------------------------------
-- OBJETIVO: distinguir descuadres SISTÉMICOS (tipos 1,2,3) cuya CAUSA es RECIENTE (= una vía de
--   escritura volvió a fugar HOY → el master debe investigar el mismo día) de los HISTÓRICOS
--   (residuo viejo, ya sellado, se arregla auditando). Additivo: nueva columna es_vivo, calculada
--   dentro de reconciliar_stock, expuesta en stock_diferencias_listar como esVivo.
--   NO toca wh.stock ni ninguna vía de escritura de stock. Solo escribe mos.stock_diferencias.
--
-- Definición de VIVO (ventana = MOS_RECON_VIVO_DIAS, default 3):
--   · TIPO 1 (stock congelado)    → el último movimiento de kardex del producto está dentro de N días.
--   · TIPO 2 (kardex inconsistente)→ la rotura de cadena MÁS RECIENTE del producto está dentro de N días.
--   · TIPO 3 (salida sin descuento)→ la guía CERRADA-sin-movimiento es de los últimos N días.
--   · resto (4,5,zona,NULL)        → es_vivo = false (no aplica el concepto de recencia sistémica).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- 1) Columna additiva (idempotente)
alter table mos.stock_diferencias
  add column if not exists es_vivo boolean not null default false;

comment on column mos.stock_diferencias.es_vivo is
  'Tripwire: TRUE si un descuadre SISTÉMICO (tipo 1/2/3) tiene causa RECIENTE (dentro de MOS_RECON_VIVO_DIAS). Distingue regresión viva (investigar hoy) de residuo histórico (auditar). Solo aplica a 1/2/3; false en el resto.';

-- 2) Helper: ventana de recencia (config-overridable, default 3 días)
create or replace function mos._recon_vivo_dias()
returns integer
language plpgsql
stable security definer
set search_path to ''
as $$
declare v int;
begin
  begin
    select nullif(btrim(valor),'')::int into v from mos.config where clave='MOS_RECON_VIVO_DIAS' limit 1;
  exception when others then v := null; end;
  v := coalesce(v, 3);
  if v < 1 then v := 3; end if;
  return v;
end;
$$;

-- 3) reconciliar_stock: recompute es_vivo para tipos sistémicos (1,2,3) en cada corrida.
--    (Re-evalúa TODO el universo → la recencia se recalcula sola; lo no tipificado sigue en "Otro".)
create or replace function mos.reconciliar_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_amb    text := upper(btrim(coalesce(p->>'ambito','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_umb    numeric := mos._recon_umbral();
  v_dia    date := (now() at time zone 'America/Lima')::date;
  v_n_zona int := 0;
  v_n_alm  int := 0;
  v_n_t3   int := 0;
  v_n_t5   int := 0;
  r        record;
  v_teo    numeric(20,3);
  v_dif    numeric(20,3);
  v_desc   text;
  v_hip    text;
  v_tipo   smallint;
  v_lb     int := mos._recon_tipo3_lookback();
  v_era    date;
  v_t3from date;
  -- ── tripwire ──
  v_vd     int := mos._recon_vivo_dias();
  v_cutts  timestamptz := now() - make_interval(days => mos._recon_vivo_dias());
  v_vivo   boolean;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- ══ ZONA (SIN CAMBIOS · es_vivo siempre false aquí) ══════════════════════════════════════════════════
  if v_amb = '' or v_amb = 'ZONA' then
    for r in
      select upper(btrim(sz.zona_id)) as zona, btrim(sz.cod_barras) as cod,
             sum(coalesce(sz.cantidad,0)) as realq
        from me.stock_zonas sz
       where nullif(btrim(sz.cod_barras),'') is not null
         and nullif(btrim(sz.zona_id),'') is not null
         and (v_zona = '' or upper(btrim(sz.zona_id)) = v_zona)
       group by upper(btrim(sz.zona_id)), btrim(sz.cod_barras)
    loop
      v_teo := mos._recon_teorico_zona(r.zona, array[r.cod]);
      v_dif := coalesce(r.realq,0) - coalesce(v_teo,0);

      if abs(v_dif) > v_umb then
        select coalesce(nullif(btrim(pr.descripcion),''), r.cod) into v_desc
          from mos.productos pr where pr.codigo_barra = r.cod limit 1;
        v_desc := coalesce(v_desc, r.cod);
        v_hip := case
          when v_teo = 0 and r.realq <> 0 then 'Sin ancla de auditoría ni movimientos en la sombra para este código → teórico=0; falta auditar o sombra incompleta.'
          when v_dif > 0 then 'Sobrante físico: hay más en zona que lo que explican auditoría+guías−ventas (ventas no registradas / ingreso sin guía / mal conteo).'
          else 'Faltante físico: hay menos en zona que lo teórico (merma / venta no descontada / traslado sin guía).'
        end;
        v_tipo := case when coalesce(v_teo,0) = 0 and coalesce(r.realq,0) <> 0 then 4 else null end;

        insert into mos.stock_diferencias
          (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado, tipo_error, tipo_etiqueta, es_vivo)
        values
          ('ZONA', r.zona, r.cod, v_desc, r.realq, v_teo, v_dif, v_hip, '{}'::jsonb, v_dia, now(), 'ABIERTA', v_tipo, mos._recon_tipo_etiqueta(v_tipo), false)
        on conflict (ambito, zona_id, cod_barra, dia) do update set
          descripcion = excluded.descripcion, real_qty = excluded.real_qty,
          teorico_qty = excluded.teorico_qty, diferencia = excluded.diferencia,
          motivo_hipotesis = excluded.motivo_hipotesis, detectado_ts = now(),
          tipo_error = excluded.tipo_error, tipo_etiqueta = excluded.tipo_etiqueta, es_vivo = excluded.es_vivo,
          estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
        v_n_zona := v_n_zona + 1;
      else
        delete from mos.stock_diferencias
         where ambito='ZONA' and zona_id=r.zona and cod_barra=r.cod and dia=v_dia and estado='ABIERTA';
      end if;
    end loop;
  end if;

  -- ══ ALMACEN (FIX A · teórico anclado en el último re-conteo) ══════════════════════════════════════════
  if v_amb = '' or v_amb = 'ALMACEN' then
    for r in
      with stk as (
        select btrim(cod_producto) cod,
               sum(coalesce(cantidad_disponible,0)) realq,
               max(ultima_actualizacion)            stk_upd
          from wh.stock where btrim(coalesce(cod_producto,'')) <> '' group by btrim(cod_producto)
      ),
      corte as (
        select cod_producto cod, cantidad_base base, fecha_corte fc from wh.auditoria_corte
      ),
      anchor as (
        select distinct on (btrim(m.cod_producto))
               btrim(m.cod_producto) cod, m.stock_despues saldo, m.fecha afecha, m.id_mov aid
          from wh.stock_movimientos m
         where mos._recon_es_reconteo(m.tipo_operacion)
           and btrim(coalesce(m.cod_producto,'')) <> ''
         order by btrim(m.cod_producto), m.fecha desc, m.id_mov desc
      ),
      post as (
        select btrim(m.cod_producto) cod, sum(coalesce(m.delta,0)) d
          from wh.stock_movimientos m
          join anchor a on a.cod = btrim(m.cod_producto)
         where not mos._recon_es_reconteo(m.tipo_operacion)
           and (m.fecha > a.afecha or (m.fecha = a.afecha and m.id_mov > a.aid))
         group by btrim(m.cod_producto)
      ),
      movc as (
        select btrim(m.cod_producto) cod, sum(coalesce(m.delta,0)) d
          from wh.stock_movimientos m
          join corte c on c.cod = btrim(m.cod_producto)
         where m.fecha > c.fc
         group by btrim(m.cod_producto)
      ),
      kar as (   -- último saldo del libro mayor por producto (testigo TIPO 1) + su fecha
        select distinct on (btrim(m.cod_producto)) btrim(m.cod_producto) cod, m.stock_despues saldo, m.fecha last_fecha
          from wh.stock_movimientos m
         where btrim(coalesce(m.cod_producto,'')) <> ''
         order by btrim(m.cod_producto), m.fecha desc, m.id_mov desc
      ),
      gap as (   -- ¿la cadena del kardex está ROTA? (TIPO 2) + FECHA de la rotura MÁS RECIENTE (tripwire)
        select cod, bool_or(brecha) tiene_gap, max(fecha) filter (where brecha) last_gap_fecha
          from (
            select btrim(m.cod_producto) cod, m.fecha,
                   (m.stock_antes is distinct from
                      lag(m.stock_despues) over (partition by btrim(m.cod_producto) order by m.fecha, m.id_mov)) as brecha,
                   lag(m.stock_despues) over (partition by btrim(m.cod_producto) order by m.fecha, m.id_mov) as prev
              from wh.stock_movimientos m
             where btrim(coalesce(m.cod_producto,'')) <> ''
          ) q
         where prev is not null
         group by cod
      )
      select coalesce(s.cod, c.cod, a.cod) as cod,
             coalesce(s.realq, 0)                                   as realq,
             case when a.cod is not null
                  then a.saldo + coalesce(po.d, 0)
                  else coalesce(c.base, 0) + coalesce(mc.d, 0) end  as teorico,
             (a.cod is not null)                                    as tiene_ancla,
             a.afecha                                               as ancla_fecha,
             a.saldo                                                as ancla_saldo,
             k.saldo                                                as saldo_kardex,
             k.last_fecha                                           as kardex_fecha,
             s.stk_upd                                              as stk_upd,
             coalesce(g.tiene_gap, false)                           as kardex_gap,
             g.last_gap_fecha                                       as kardex_gap_fecha,
             (c.cod is null)                                        as sin_corte
        from stk s
        full outer join corte c on c.cod = s.cod
        left  join anchor a on a.cod = coalesce(s.cod, c.cod)
        left  join post   po on po.cod = coalesce(s.cod, c.cod, a.cod)
        left  join movc   mc on mc.cod = coalesce(s.cod, c.cod)
        left  join kar    k on k.cod = coalesce(s.cod, c.cod, a.cod)
        left  join gap    g on g.cod = coalesce(s.cod, c.cod, a.cod)
    loop
      v_dif := coalesce(r.realq,0) - coalesce(r.teorico,0);
      if abs(v_dif) > v_umb then
        select coalesce(nullif(btrim(pr.descripcion),''), r.cod) into v_desc
          from mos.productos pr where pr.codigo_barra = r.cod limit 1;
        v_desc := coalesce(v_desc, r.cod);

        v_tipo := null;
        if r.saldo_kardex is not null
           and v_dif > 0
           and abs(coalesce(r.realq,0) - r.saldo_kardex) > v_umb
           and r.stk_upd is not null and r.kardex_fecha is not null
           and r.stk_upd < r.kardex_fecha then
          v_tipo := 1;
        elsif coalesce(r.kardex_gap,false) then
          v_tipo := 2;
        elsif ((not r.tiene_ancla and r.sin_corte) or coalesce(r.teorico,0) = 0) and coalesce(r.realq,0) > 0 then
          v_tipo := 4;
        end if;

        -- ── TRIPWIRE: vivo si la CAUSA del tipo sistémico es reciente ──────────────────────────────────
        v_vivo := case
          when v_tipo = 1 then (r.kardex_fecha is not null and r.kardex_fecha >= v_cutts)
          when v_tipo = 2 then (r.kardex_gap_fecha is not null and r.kardex_gap_fecha >= v_cutts)
          else false  -- tipo 4 / NULL: no aplica recencia sistémica
        end;

        v_hip := case
          when v_tipo = 1 then 'Stock congelado: la tabla de stock no siguió al kardex (real≠saldo_kardex, stock desactualizado). Revisar el flujo que escribe wh.stock.'
          when v_tipo = 2 then 'Kardex inconsistente: la cadena de movimientos no cierra (stock_antes≠stock_despues del anterior). Renormalizar el libro mayor / re-anclar con auditoría.'
          when v_tipo = 4 then 'Producto sin re-conteo ni corte de auditoría → teórico no confiable; tomar/renovar conteo de almacén.'
          when v_dif > 0 then 'Sobrante en almacén vs último re-conteo + movimientos posteriores (ingreso sin movimiento / re-conteo desfasado).'
          else 'Faltante en almacén vs último re-conteo + movimientos posteriores (merma / salida sin movimiento / re-conteo desfasado).'
        end;

        insert into mos.stock_diferencias
          (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado, tipo_error, tipo_etiqueta, es_vivo)
        values
          ('ALMACEN', '', r.cod, v_desc, r.realq, r.teorico, v_dif, v_hip,
           jsonb_build_object('saldoKardex', r.saldo_kardex, 'sinCorte', r.sin_corte,
                              'kardexGap', r.kardex_gap, 'kardexGapFecha', r.kardex_gap_fecha,
                              'stkUpd', r.stk_upd, 'kardexFecha', r.kardex_fecha,
                              'tieneAncla', r.tiene_ancla, 'anclaSaldo', r.ancla_saldo, 'anclaFecha', r.ancla_fecha),
           v_dia, now(), 'ABIERTA', v_tipo, mos._recon_tipo_etiqueta(v_tipo), v_vivo)
        on conflict (ambito, zona_id, cod_barra, dia) do update set
          descripcion = excluded.descripcion, real_qty = excluded.real_qty,
          teorico_qty = excluded.teorico_qty, diferencia = excluded.diferencia,
          motivo_hipotesis = excluded.motivo_hipotesis, detalle = excluded.detalle, detectado_ts = now(),
          tipo_error = excluded.tipo_error, tipo_etiqueta = excluded.tipo_etiqueta, es_vivo = excluded.es_vivo,
          estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
        v_n_alm := v_n_alm + 1;
      else
        delete from mos.stock_diferencias
         where ambito='ALMACEN' and zona_id='' and cod_barra=r.cod and dia=v_dia and estado='ABIERTA'
           and coalesce(tipo_error,0) not in (3,5);
      end if;
    end loop;

    -- ── TIPO 3 · Salida-a-zona sin descuento de origen (filas-aviso) · es_vivo = guía reciente ──────────
    select (min(m.fecha) at time zone 'America/Lima')::date into v_era
      from wh.stock_movimientos m
     where m.tipo_operacion = 'CIERRE_GUIA' and m.origen like 'G%';
    v_era    := coalesce(v_era, v_dia - v_lb);
    v_t3from := greatest(v_era, v_dia - v_lb);

    delete from mos.stock_diferencias
     where ambito='ALMACEN' and dia=v_dia and tipo_error=3 and estado='ABIERTA';

    for r in
      select g.id_guia, upper(g.tipo) as tipo, g.fecha as gts, (g.fecha at time zone 'America/Lima')::date as gdia
        from wh.guias g
       where upper(g.tipo) in ('SALIDA_ZONA','SALIDA_JEFATURA')
         and upper(g.estado) = 'CERRADA'
         and (g.fecha at time zone 'America/Lima')::date >= v_t3from
         and not exists (select 1 from wh.stock_movimientos m where m.origen = g.id_guia)
    loop
      v_vivo := (r.gts is not null and r.gts >= v_cutts);  -- TIPO 3 vivo: la guía-sin-descuento es de últimos N días
      v_desc := 'Salida ' || r.tipo || ' cerrada SIN descuento de almacén (guía ' || r.id_guia || ', ' || to_char(r.gdia,'YYYY-MM-DD') || ')';
      insert into mos.stock_diferencias
        (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado, tipo_error, tipo_etiqueta, es_vivo)
      values
        ('ALMACEN', '', r.id_guia, v_desc, 0, 0, 0,
         'Salida-a-zona sin descuento de origen: guía CERRADA sin movimiento en el kardex del almacén (reincidencia del bug del flujo de despacho). Revisar el cierre de guía / espejo de detalle.',
         jsonb_build_object('idGuia', r.id_guia, 'tipoGuia', r.tipo, 'guiaDia', to_char(r.gdia,'YYYY-MM-DD')),
         v_dia, now(), 'ABIERTA', 3, mos._recon_tipo_etiqueta(3), v_vivo)
      on conflict (ambito, zona_id, cod_barra, dia) do update set
        descripcion = excluded.descripcion, motivo_hipotesis = excluded.motivo_hipotesis,
        detalle = excluded.detalle, detectado_ts = now(),
        tipo_error = 3, tipo_etiqueta = excluded.tipo_etiqueta, es_vivo = excluded.es_vivo,
        estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
      v_n_t3 := v_n_t3 + 1;
    end loop;

    -- ── TIPO 5 · Factor no configurado (filas-aviso · es_vivo=false, es config no recencia) ─────────────
    delete from mos.stock_diferencias
     where ambito='ALMACEN' and dia=v_dia and tipo_error=5 and estado='ABIERTA';

    for r in
      select pr.codigo_barra as cod, coalesce(nullif(btrim(pr.descripcion),''), pr.codigo_barra) as descr
        from mos.productos pr
       where pr.tipo_producto = 'DERIVADO'
         and pr.estado = true
         and pr.factor_conversion_base is null
         and nullif(btrim(pr.codigo_barra),'') is not null
    loop
      insert into mos.stock_diferencias
        (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado, tipo_error, tipo_etiqueta, es_vivo)
      values
        ('ALMACEN', '', r.cod, 'Factor de conversión no configurado · ' || r.descr, 0, 0, 0,
         'Producto DERIVADO sin factor_conversion_base → el envasado se bloquea (revierte atómico). Configurar el factor en el catálogo.',
         jsonb_build_object('config', true, 'tipoProducto', 'DERIVADO'),
         v_dia, now(), 'ABIERTA', 5, mos._recon_tipo_etiqueta(5), false)
      on conflict (ambito, zona_id, cod_barra, dia) do update set
        descripcion = excluded.descripcion, motivo_hipotesis = excluded.motivo_hipotesis,
        detalle = excluded.detalle, detectado_ts = now(),
        tipo_error = 5, tipo_etiqueta = excluded.tipo_etiqueta, es_vivo = false,
        estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
      v_n_t5 := v_n_t5 + 1;
    end loop;
  end if;

  -- ══ FIX B (housekeeping) · purgar filas ABIERTAS de DÍAS ANTERIORES de los ámbitos reconciliados hoy ══
  if v_amb = '' or v_amb = 'ZONA' then
    delete from mos.stock_diferencias
     where ambito='ZONA' and estado='ABIERTA' and dia < v_dia
       and (v_zona = '' or zona_id = v_zona);
  end if;
  if v_amb = '' or v_amb = 'ALMACEN' then
    delete from mos.stock_diferencias
     where ambito='ALMACEN' and estado='ABIERTA' and dia < v_dia;
  end if;

  return jsonb_build_object('ok', true, 'dia', to_char(v_dia,'YYYY-MM-DD'),
    'umbral', v_umb, 'difZona', v_n_zona, 'difAlmacen', v_n_alm,
    'tipo3', v_n_t3, 'tipo5', v_n_t5, 'vivoDias', v_vd,
    'total', v_n_zona + v_n_alm + v_n_t3 + v_n_t5);
end;
$function$;

-- 4) stock_diferencias_listar: exponer esVivo (additivo)
create or replace function mos.stock_diferencias_listar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_amb  text := nullif(upper(btrim(coalesce(p->>'ambito',''))),'');
  v_zona text := nullif(upper(btrim(coalesce(p->>'zona',''))),'');
  v_est  text := nullif(upper(btrim(coalesce(p->>'estado',''))),'');
  v_tipo text := nullif(btrim(coalesce(p->>'tipo','')),'');
  v_arr  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  with filtradas as (
    select d.*
      from mos.stock_diferencias d
     where (v_amb  is null or d.ambito = v_amb)
       and (v_zona is null or d.zona_id = v_zona)
       and (v_est  is null or d.estado = v_est)
       and (v_tipo is null or coalesce(d.tipo_error,0)::text = v_tipo)
  ),
  vigentes as (
    select distinct on (f.ambito, f.zona_id, f.cod_barra) f.*
      from filtradas f
     order by f.ambito, f.zona_id, f.cod_barra, f.dia desc, f.id desc
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',              v.id,
           'ambito',          v.ambito,
           'zonaId',          v.zona_id,
           'codBarra',        v.cod_barra,
           'descripcion',     coalesce(v.descripcion, v.cod_barra),
           'real',            v.real_qty,
           'teorico',         v.teorico_qty,
           'diferencia',      v.diferencia,
           'motivoHipotesis', coalesce(v.motivo_hipotesis,''),
           'detalle',         coalesce(v.detalle,'{}'::jsonb),
           'dia',             to_char(v.dia,'YYYY-MM-DD'),
           'detectadoTs',     to_char(v.detectado_ts at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'estado',          v.estado,
           'tipoError',       v.tipo_error,
           'tipoEtiqueta',    coalesce(v.tipo_etiqueta, mos._recon_tipo_etiqueta(v.tipo_error)),
           'esVivo',          coalesce(v.es_vivo, false)
         ) order by abs(v.diferencia) desc, v.detectado_ts desc), '[]'::jsonb) into v_arr
    from vigentes v;

  return jsonb_build_object('ok', true, 'data',
           jsonb_build_object('total', jsonb_array_length(v_arr), 'items', v_arr))
         || mos._frescura_sombra();
end;
$function$;
