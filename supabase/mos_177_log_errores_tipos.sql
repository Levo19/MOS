-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- MOS · supabase/177 — TAXONOMÍA de errores en el "Log de errores" (reconciliación de stock).
-- ----------------------------------------------------------------------------------------------------------
-- ADITIVO y MONEY-SAFE: NO toca el cálculo de stock ni los números base (real/teorico/diferencia).
-- Solo (1) agrega columnas de etiqueta y (2) CLASIFICA cada diferencia con un TIPO 1-5 según señales
-- COMPUTABLES sobre los datos reales. La lógica de detección de diferencias queda intacta.
--
-- TAXONOMÍA (acordada con el dueño; aplica a ALMACEN, ZONA-01, ZONA-02):
--   TIPO 1 · Stock congelado (LOPESA): la tabla de stock no sigue al kardex → real ≠ saldo_kardex,
--            stock.ultima_actualizacion STALE vs el último mov del kardex, y diferencia = sobrante (real>teo).
--            [Computable solo en ALMACEN: hay tabla wh.stock con ultima_actualizacion + kardex testigo.]
--   TIPO 2 · Saldo del kardex inconsistente: la corrida del kardex NO cierra → existe un mov con
--            stock_antes <> stock_despues del anterior (cadena rota). [Computable en ALMACEN.]
--   TIPO 3 · Salida-a-zona sin descuento de origen: guía SALIDA_ZONA/SALIDA_JEFATURA CERRADA con 0
--            movimientos en el kardex del almacén. Fila propia (ambito ALMACEN). DETECTA reincidencia.
--            Acotado a la ERA del kardex (>= primer CIERRE_GUIA) + ventana reciente → no dredgea legacy.
--   TIPO 4 · Sin ancla / nunca auditado: teorico=0 / sin corte, con real>0. [ZONA y ALMACEN.]
--   TIPO 5 · Factor no configurado: producto DERIVADO con factor_conversion_base NULL → advertencia
--            informativa (config, no diferencia de stock). Fila propia (ambito ALMACEN, real=teo=dif=0).
--
-- PRIORIDAD de etiqueta para una MISMA fila de diferencia (cada fila lleva 1 tipo):
--   TIPO 1 (congelado)  >  TIPO 2 (kardex roto)  >  TIPO 4 (sin ancla)  >  NULL (otro: sobrante/faltante común).
-- (TIPO 3 y TIPO 5 son filas APARTE, insertadas por bloques dedicados; no compiten por prioridad.)
--
-- Reaplica idempotente: las columnas usan IF NOT EXISTS; la función es CREATE OR REPLACE; las filas
-- TIPO 3/5 usan el mismo upsert por (ambito,zona_id,cod_barra,dia) que el resto (índice uq existente).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1) Columnas de etiqueta (aditivas) ──────────────────────────────────────────────────────────────────
alter table mos.stock_diferencias add column if not exists tipo_error    smallint;
alter table mos.stock_diferencias add column if not exists tipo_etiqueta text;

comment on column mos.stock_diferencias.tipo_error    is 'Taxonomía MOS 1-5: 1=stock congelado,2=kardex inconsistente,3=salida sin descuento,4=sin ancla,5=factor no configurado. NULL=otro (sobrante/faltante común).';
comment on column mos.stock_diferencias.tipo_etiqueta is 'Nombre corto humano del tipo_error (espejo legible).';

-- ── 1b) Config: ventana de lookback para TIPO 3 (días). Default 30. ─────────────────────────────────────
insert into mos.config (clave, valor)
  select 'MOS_RECON_TIPO3_LOOKBACK_DIAS', '30'
  where not exists (select 1 from mos.config where clave = 'MOS_RECON_TIPO3_LOOKBACK_DIAS');

-- helper: ventana de lookback TIPO 3 (días). Tolerante a config ausente/inválida.
create or replace function mos._recon_tipo3_lookback()
returns int language plpgsql stable security definer set search_path to '' as $$
declare v int;
begin
  begin
    select nullif(btrim(valor),'')::int into v from mos.config where clave='MOS_RECON_TIPO3_LOOKBACK_DIAS' limit 1;
  exception when others then v := null; end;
  v := coalesce(v, 30);
  if v < 1 then v := 30; end if;
  return v;
end;
$$;

-- helper: etiqueta humana por tipo (única fuente de verdad para el espejo de texto).
create or replace function mos._recon_tipo_etiqueta(p_tipo smallint)
returns text language sql immutable set search_path to '' as $$
  select case p_tipo
    when 1 then 'Stock congelado'
    when 2 then 'Kardex inconsistente'
    when 3 then 'Salida sin descuento'
    when 4 then 'Sin ancla / sin auditar'
    when 5 then 'Factor no configurado'
    else null end;
$$;

-- ── 2) reconciliar_stock con clasificación aditiva ──────────────────────────────────────────────────────
create or replace function mos.reconciliar_stock(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
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
  v_era    date;     -- inicio de la era del kardex (primer CIERRE_GUIA de origen guía)
  v_t3from date;     -- corte efectivo para TIPO 3 = max(era, hoy - lookback)
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- ══ ZONA ════════════════════════════════════════════════════════════════════════════════════════════════
  -- Señal computable en zona: NO hay tabla-de-stock vs kardex separadas (TIPO 1/2 no aplican aquí).
  -- Solo distinguimos TIPO 4 (sin ancla: teorico=0 con real<>0) del resto (NULL = sobrante/faltante común).
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
        -- CLASIFICACIÓN ZONA: solo TIPO 4 es computable; el resto queda NULL (común).
        v_tipo := case when coalesce(v_teo,0) = 0 and coalesce(r.realq,0) <> 0 then 4 else null end;

        insert into mos.stock_diferencias
          (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado, tipo_error, tipo_etiqueta)
        values
          ('ZONA', r.zona, r.cod, v_desc, r.realq, v_teo, v_dif, v_hip, '{}'::jsonb, v_dia, now(), 'ABIERTA', v_tipo, mos._recon_tipo_etiqueta(v_tipo))
        on conflict (ambito, zona_id, cod_barra, dia) do update set
          descripcion = excluded.descripcion, real_qty = excluded.real_qty,
          teorico_qty = excluded.teorico_qty, diferencia = excluded.diferencia,
          motivo_hipotesis = excluded.motivo_hipotesis, detectado_ts = now(),
          tipo_error = excluded.tipo_error, tipo_etiqueta = excluded.tipo_etiqueta,
          estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
        v_n_zona := v_n_zona + 1;
      else
        delete from mos.stock_diferencias
         where ambito='ZONA' and zona_id=r.zona and cod_barra=r.cod and dia=v_dia and estado='ABIERTA';
      end if;
    end loop;
  end if;

  -- ══ ALMACEN ═════════════════════════════════════════════════════════════════════════════════════════════
  if v_amb = '' or v_amb = 'ALMACEN' then
    for r in
      with stk as (
        select btrim(cod_producto) cod,
               sum(coalesce(cantidad_disponible,0)) realq,
               max(ultima_actualizacion)            stk_upd      -- frescura de la tabla de stock
          from wh.stock where btrim(coalesce(cod_producto,'')) <> '' group by btrim(cod_producto)
      ),
      corte as (
        select cod_producto cod, cantidad_base base, fecha_corte fc from wh.auditoria_corte
      ),
      mov as (
        select btrim(m.cod_producto) cod, sum(coalesce(m.delta,0)) d
          from wh.stock_movimientos m
          join corte c on c.cod = btrim(m.cod_producto)
         where m.fecha > c.fc
         group by btrim(m.cod_producto)
      ),
      kar as (   -- último saldo del libro mayor por producto (testigo secundario) + su fecha
        select distinct on (btrim(m.cod_producto)) btrim(m.cod_producto) cod, m.stock_despues saldo, m.fecha last_fecha
          from wh.stock_movimientos m
         where btrim(coalesce(m.cod_producto,'')) <> ''
         order by btrim(m.cod_producto), m.fecha desc, m.id_mov desc
      ),
      gap as (   -- ¿la cadena del kardex está ROTA? exists mov con stock_antes <> stock_despues del anterior
        select cod, bool_or(brecha) tiene_gap
          from (
            select btrim(m.cod_producto) cod,
                   (m.stock_antes is distinct from
                      lag(m.stock_despues) over (partition by btrim(m.cod_producto) order by m.fecha, m.id_mov)) as brecha,
                   lag(m.stock_despues) over (partition by btrim(m.cod_producto) order by m.fecha, m.id_mov) as prev
              from wh.stock_movimientos m
             where btrim(coalesce(m.cod_producto,'')) <> ''
          ) q
         where prev is not null   -- ignora el primer mov (no tiene anterior)
         group by cod
      )
      select coalesce(s.cod, c.cod) as cod,
             coalesce(s.realq, 0)                          as realq,
             coalesce(c.base, 0) + coalesce(m.d, 0)        as teorico,
             k.saldo                                       as saldo_kardex,
             k.last_fecha                                  as kardex_fecha,
             s.stk_upd                                     as stk_upd,
             coalesce(g.tiene_gap, false)                  as kardex_gap,
             (c.cod is null)                               as sin_corte
        from stk s
        full outer join corte c on c.cod = s.cod
        left  join mov   m on m.cod = coalesce(s.cod, c.cod)
        left  join kar   k on k.cod = coalesce(s.cod, c.cod)
        left  join gap   g on g.cod = coalesce(s.cod, c.cod)
    loop
      v_dif := coalesce(r.realq,0) - coalesce(r.teorico,0);
      if abs(v_dif) > v_umb then
        select coalesce(nullif(btrim(pr.descripcion),''), r.cod) into v_desc
          from mos.productos pr where pr.codigo_barra = r.cod limit 1;
        v_desc := coalesce(v_desc, r.cod);

        -- ── CLASIFICACIÓN ALMACEN (prioridad: 1 congelado > 2 kardex roto > 4 sin ancla > NULL) ──
        v_tipo := null;
        -- TIPO 1 · stock congelado: sobrante + |real-saldo_kardex| significativo + tabla stale vs kardex.
        if r.saldo_kardex is not null
           and v_dif > 0
           and abs(coalesce(r.realq,0) - r.saldo_kardex) > v_umb
           and r.stk_upd is not null and r.kardex_fecha is not null
           and r.stk_upd < r.kardex_fecha then
          v_tipo := 1;
        -- TIPO 2 · kardex inconsistente: la cadena del libro mayor no cierra (gap stock_antes<>prev despues).
        elsif coalesce(r.kardex_gap,false) then
          v_tipo := 2;
        -- TIPO 4 · sin ancla: sin corte de auditoría (o teorico=0) con real>0.
        elsif (r.sin_corte or coalesce(r.teorico,0) = 0) and coalesce(r.realq,0) > 0 then
          v_tipo := 4;
        end if;

        v_hip := case
          when v_tipo = 1 then 'Stock congelado: la tabla de stock no siguió al kardex (real≠saldo_kardex, stock desactualizado). Revisar el flujo que escribe wh.stock.'
          when v_tipo = 2 then 'Kardex inconsistente: la cadena de movimientos no cierra (stock_antes≠stock_despues del anterior). Renormalizar el libro mayor / re-anclar con auditoría.'
          when v_tipo = 4 then 'Producto sin snapshot de corte → teórico parcial; tomar/renovar corte de almacén.'
          when v_dif > 0 then 'Sobrante en almacén vs corte+delta del kardex (ingreso sin movimiento / corte desfasado).'
          else 'Faltante en almacén vs corte+delta del kardex (merma / salida sin movimiento / corte desfasado).'
        end;

        insert into mos.stock_diferencias
          (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado, tipo_error, tipo_etiqueta)
        values
          ('ALMACEN', '', r.cod, v_desc, r.realq, r.teorico, v_dif, v_hip,
           jsonb_build_object('saldoKardex', r.saldo_kardex, 'sinCorte', r.sin_corte,
                              'kardexGap', r.kardex_gap, 'stkUpd', r.stk_upd, 'kardexFecha', r.kardex_fecha),
           v_dia, now(), 'ABIERTA', v_tipo, mos._recon_tipo_etiqueta(v_tipo))
        on conflict (ambito, zona_id, cod_barra, dia) do update set
          descripcion = excluded.descripcion, real_qty = excluded.real_qty,
          teorico_qty = excluded.teorico_qty, diferencia = excluded.diferencia,
          motivo_hipotesis = excluded.motivo_hipotesis, detalle = excluded.detalle, detectado_ts = now(),
          tipo_error = excluded.tipo_error, tipo_etiqueta = excluded.tipo_etiqueta,
          estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
        v_n_alm := v_n_alm + 1;
      else
        delete from mos.stock_diferencias
         where ambito='ALMACEN' and zona_id='' and cod_barra=r.cod and dia=v_dia and estado='ABIERTA'
           and coalesce(tipo_error,0) not in (3,5);   -- NO borrar las filas-aviso T3/T5 (no son diferencias de stock)
      end if;
    end loop;

    -- ── TIPO 3 · Salida-a-zona sin descuento de origen (filas-aviso, ambito ALMACEN) ──────────────────────
    --   Guía SALIDA_ZONA/SALIDA_JEFATURA CERRADA, dentro de la ERA del kardex + ventana de lookback,
    --   sin NINGÚN movimiento de kardex con origen = id_guia. cod_barra = id_guia (clave estable del aviso).
    --   real/teorico=0, diferencia=0 → es advertencia, no diferencia de stock. Detecta REINCIDENCIA del bug.
    select (min(m.fecha) at time zone 'America/Lima')::date into v_era
      from wh.stock_movimientos m
     where m.tipo_operacion = 'CIERRE_GUIA' and m.origen like 'G%';
    v_era    := coalesce(v_era, v_dia - v_lb);
    v_t3from := greatest(v_era, v_dia - v_lb);

    -- limpiar avisos T3 ABIERTOS de hoy (se re-detectan a continuación; preserva REVISADA).
    delete from mos.stock_diferencias
     where ambito='ALMACEN' and dia=v_dia and tipo_error=3 and estado='ABIERTA';

    for r in
      select g.id_guia, upper(g.tipo) as tipo, (g.fecha at time zone 'America/Lima')::date as gdia
        from wh.guias g
       where upper(g.tipo) in ('SALIDA_ZONA','SALIDA_JEFATURA')
         and upper(g.estado) = 'CERRADA'
         and (g.fecha at time zone 'America/Lima')::date >= v_t3from
         and not exists (select 1 from wh.stock_movimientos m where m.origen = g.id_guia)
    loop
      v_desc := 'Salida ' || r.tipo || ' cerrada SIN descuento de almacén (guía ' || r.id_guia || ', ' || to_char(r.gdia,'YYYY-MM-DD') || ')';
      insert into mos.stock_diferencias
        (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado, tipo_error, tipo_etiqueta)
      values
        ('ALMACEN', '', r.id_guia, v_desc, 0, 0, 0,
         'Salida-a-zona sin descuento de origen: guía CERRADA sin movimiento en el kardex del almacén (reincidencia del bug del flujo de despacho). Revisar el cierre de guía / espejo de detalle.',
         jsonb_build_object('idGuia', r.id_guia, 'tipoGuia', r.tipo, 'guiaDia', to_char(r.gdia,'YYYY-MM-DD')),
         v_dia, now(), 'ABIERTA', 3, mos._recon_tipo_etiqueta(3))
      on conflict (ambito, zona_id, cod_barra, dia) do update set
        descripcion = excluded.descripcion, motivo_hipotesis = excluded.motivo_hipotesis,
        detalle = excluded.detalle, detectado_ts = now(),
        tipo_error = 3, tipo_etiqueta = excluded.tipo_etiqueta,
        estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
      v_n_t3 := v_n_t3 + 1;
    end loop;

    -- ── TIPO 5 · Factor no configurado (filas-aviso, ambito ALMACEN) ──────────────────────────────────────
    --   Producto DERIVADO activo con factor_conversion_base NULL → bloquea el envasado (revierte atómico).
    --   Es CONFIG, no diferencia de stock. cod_barra = codigo_barra del derivado. real/teo/dif=0.
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
        (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado, tipo_error, tipo_etiqueta)
      values
        ('ALMACEN', '', r.cod, 'Factor de conversión no configurado · ' || r.descr, 0, 0, 0,
         'Producto DERIVADO sin factor_conversion_base → el envasado se bloquea (revierte atómico). Configurar el factor en el catálogo.',
         jsonb_build_object('config', true, 'tipoProducto', 'DERIVADO'),
         v_dia, now(), 'ABIERTA', 5, mos._recon_tipo_etiqueta(5))
      on conflict (ambito, zona_id, cod_barra, dia) do update set
        descripcion = excluded.descripcion, motivo_hipotesis = excluded.motivo_hipotesis,
        detalle = excluded.detalle, detectado_ts = now(),
        tipo_error = 5, tipo_etiqueta = excluded.tipo_etiqueta,
        estado = case when mos.stock_diferencias.estado = 'REVISADA' then 'REVISADA' else 'ABIERTA' end;
      v_n_t5 := v_n_t5 + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'dia', to_char(v_dia,'YYYY-MM-DD'),
    'umbral', v_umb, 'difZona', v_n_zona, 'difAlmacen', v_n_alm,
    'tipo3', v_n_t3, 'tipo5', v_n_t5,
    'total', v_n_zona + v_n_alm + v_n_t3 + v_n_t5);
end;
$function$;

-- ── 3) Exponer tipo en el listado (aditivo; no rompe la forma existente) ────────────────────────────────
create or replace function mos.stock_diferencias_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_amb  text := nullif(upper(btrim(coalesce(p->>'ambito',''))),'');
  v_zona text := nullif(upper(btrim(coalesce(p->>'zona',''))),'');
  v_est  text := nullif(upper(btrim(coalesce(p->>'estado',''))),'');
  v_tipo text := nullif(btrim(coalesce(p->>'tipo','')),'');   -- filtro opcional por tipo (smallint como texto)
  v_arr  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',              d.id,
           'ambito',          d.ambito,
           'zonaId',          d.zona_id,
           'codBarra',        d.cod_barra,
           'descripcion',     coalesce(d.descripcion, d.cod_barra),
           'real',            d.real_qty,
           'teorico',         d.teorico_qty,
           'diferencia',      d.diferencia,
           'motivoHipotesis', coalesce(d.motivo_hipotesis,''),
           'detalle',         coalesce(d.detalle,'{}'::jsonb),
           'dia',             to_char(d.dia,'YYYY-MM-DD'),
           'detectadoTs',     to_char(d.detectado_ts at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'estado',          d.estado,
           'tipoError',       d.tipo_error,
           'tipoEtiqueta',    coalesce(d.tipo_etiqueta, mos._recon_tipo_etiqueta(d.tipo_error))
         ) order by abs(d.diferencia) desc, d.detectado_ts desc), '[]'::jsonb) into v_arr
    from mos.stock_diferencias d
   where (v_amb  is null or d.ambito = v_amb)
     and (v_zona is null or d.zona_id = v_zona)
     and (v_est  is null or d.estado = v_est)
     and (v_tipo is null or coalesce(d.tipo_error,0)::text = v_tipo);

  return jsonb_build_object('ok', true, 'data',
           jsonb_build_object('total', jsonb_array_length(v_arr), 'items', v_arr))
         || mos._frescura_sombra();
end;
$function$;
