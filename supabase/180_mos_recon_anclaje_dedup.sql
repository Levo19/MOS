-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- MOS · supabase/180 — RECONCILIACIÓN de stock: (A) ANCLAJE del teórico de ALMACEN en el último re-conteo,
--                       (B) DEDUP del "Log de errores" (una sola fila por ámbito×producto). SOLO LECTURA.
-- ----------------------------------------------------------------------------------------------------------
-- MONEY-SAFE: la RPC NO escribe en wh.stock / wh.stock_movimientos / kardex / guías / ventas / ajustes.
--   Solo INSERTA/UPSERTEA/limpia en mos.stock_diferencias (tabla de DIAGNÓSTICO que nadie más toca).
--   No cambia el cálculo de ZONA (intacto). No toca flags/sync/GAS/dinero. Reaplica idempotente.
--
-- ══ FIX A · ANCLAJE del teórico de ALMACEN ════════════════════════════════════════════════════════════════
--   PROBLEMA (antes): teórico ALMACEN = wh.auditoria_corte.cantidad_base (corte FIJO de la migración) +
--   Σ(TODOS los deltas del kardex posteriores al corte). Eso suma las propias AUDITORIA/AJUSTE como si
--   fueran movimientos reales y el corte NUNCA se re-ancla → un producto recién auditado/ajustado jamás
--   converge (p.ej. PISTACHO WHPIOXAL100GR: 38 + (−81) = −43 ≠ real 3 → +46 fantasma para siempre).
--
--   FIX: el ANCLA pasa a ser el RE-CONTEO MÁS RECIENTE por producto. Un re-conteo es un movimiento de tipo
--   set-absoluto donde el operador fija el saldo físico real: su stock_despues = saldo tras el conteo.
--   Tipos de re-conteo verificados en wh.stock_movimientos (todos con delta = despues−antes coherente):
--       AUDITORIA, AJUSTE_MANUAL, EDICION_CANTIDAD, CORRECCION_MANUAL_ENVASADO, EDICION_ENVASADO.
--   (El resto son movimientos REALES: CIERRE_GUIA, REABRIR_REVERSO, ENVASADO_*, ANULACION_DETALLE,
--    AUTO_SUMA_DETALLE, ENVASADO_SALIDA/INGRESO.)
--   teórico = saldo_del_ancla + Σ(delta de los movimientos POSTERIORES al ancla que NO son re-conteo)
--             (otra AUDITORIA/AJUSTE más reciente RE-ANCLA y manda; por eso el ancla es "el más reciente").
--   Si el producto NUNCA tuvo re-conteo → cae al modelo viejo (corte + Σ deltas posteriores al corte).
--
--   RESULTADO esperado: PISTACHO → ancla AJUSTE_MANUAL (stock_despues=3) sin movs reales posteriores →
--   teórico=3 = real 3 → diferencia 0 → SALE del log. Los productos con wh.stock realmente desincronizado
--   del último re-conteo (TIPO 1 congelado / TIPO 2 kardex roto) SIGUEN apareciendo (real ≠ teórico anclado).
--
--   CASO BORDE (documentado, NO inventado): productos cuya cadena de kardex traía huecos ANTERIORES
--   (stock_antes ≠ stock_despues del previo, p.ej. por REABRIR_REVERSO mal encadenado) pueden, tras anclar,
--   mostrar una diferencia NUEVA que el modelo viejo "corte+delta" ocultaba por coincidencia. Esa diferencia
--   es REAL (el saldo posterior al re-conteo no cuadra con wh.stock) y es correcto que el master la vea.
--   Si fuese un ajuste erróneo del operador, se corrige re-contando — no se enmascara aquí.
--
-- ══ FIX B · DEDUP del Log (una sola fila por ámbito×producto[×zona]) ═══════════════════════════════════════
--   PROBLEMA: mos.stock_diferencias guarda una fila por (ambito, zona, cod, DÍA) y la reconciliación de cada
--   día crea una fila nueva, pero el listado devolvía TODAS las filas ABIERTAS de TODOS los días → un mismo
--   producto aparecía repetido (una por 2026-06-17, otra por 2026-06-18, etc.). Eso es el "duplicado".
--   FIX: (1) el LISTADO devuelve solo la fila MÁS RECIENTE por (ambito, zona_id, cod_barra) [distinct on];
--        (2) la reconciliación, al terminar, PURGA las filas ABIERTAS de DÍAS ANTERIORES (housekeeping: son
--            diagnóstico re-derivable; preserva REVISADA y el día de hoy). Así la bitácora no crece sin fin.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;

-- ── helper: ¿un tipo_operacion es un RE-CONTEO (set-absoluto que re-ancla el saldo)? ─────────────────────
--   Única fuente de verdad del filtro de anclaje (lo usan el ancla y el cálculo de deltas posteriores).
create or replace function mos._recon_es_reconteo(p_tipo text)
returns boolean language sql immutable set search_path to '' as $$
  select upper(coalesce(p_tipo,'')) in
    ('AUDITORIA','AJUSTE_MANUAL','EDICION_CANTIDAD','CORRECCION_MANUAL_ENVASADO','EDICION_ENVASADO');
$$;
revoke all on function mos._recon_es_reconteo(text) from public;
grant execute on function mos._recon_es_reconteo(text) to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- reconciliar_stock — FIX A (anclaje ALMACEN) + FIX B (purga de días anteriores). ZONA intacta.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
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
  v_era    date;
  v_t3from date;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- ══ ZONA (SIN CAMBIOS) ════════════════════════════════════════════════════════════════════════════════
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
      -- ── ANCLA: re-conteo MÁS RECIENTE por producto (su stock_despues = saldo físico tras el conteo) ──
      anchor as (
        select distinct on (btrim(m.cod_producto))
               btrim(m.cod_producto) cod, m.stock_despues saldo, m.fecha afecha, m.id_mov aid
          from wh.stock_movimientos m
         where mos._recon_es_reconteo(m.tipo_operacion)
           and btrim(coalesce(m.cod_producto,'')) <> ''
         order by btrim(m.cod_producto), m.fecha desc, m.id_mov desc
      ),
      -- ── deltas POSTERIORES al ancla que NO son re-conteo (los re-conteo re-anclan, no suman) ──
      post as (
        select btrim(m.cod_producto) cod, sum(coalesce(m.delta,0)) d
          from wh.stock_movimientos m
          join anchor a on a.cod = btrim(m.cod_producto)
         where not mos._recon_es_reconteo(m.tipo_operacion)
           and (m.fecha > a.afecha or (m.fecha = a.afecha and m.id_mov > a.aid))
         group by btrim(m.cod_producto)
      ),
      -- ── modelo VIEJO (corte + Σ deltas posteriores al corte) — fallback para productos SIN ancla ──
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
      gap as (   -- ¿la cadena del kardex está ROTA? (TIPO 2)
        select cod, bool_or(brecha) tiene_gap
          from (
            select btrim(m.cod_producto) cod,
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
             -- teórico ANCLADO si hay re-conteo; si no, modelo viejo corte+delta.
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

        -- ── CLASIFICACIÓN ALMACEN (prioridad: 1 congelado > 2 kardex roto > 4 sin ancla > NULL) ──
        v_tipo := null;
        if r.saldo_kardex is not null
           and v_dif > 0
           and abs(coalesce(r.realq,0) - r.saldo_kardex) > v_umb
           and r.stk_upd is not null and r.kardex_fecha is not null
           and r.stk_upd < r.kardex_fecha then
          v_tipo := 1;
        elsif coalesce(r.kardex_gap,false) then
          v_tipo := 2;
        -- TIPO 4 · sin ancla: ni re-conteo ni corte (o teorico=0) con real>0.
        elsif ((not r.tiene_ancla and r.sin_corte) or coalesce(r.teorico,0) = 0) and coalesce(r.realq,0) > 0 then
          v_tipo := 4;
        end if;

        v_hip := case
          when v_tipo = 1 then 'Stock congelado: la tabla de stock no siguió al kardex (real≠saldo_kardex, stock desactualizado). Revisar el flujo que escribe wh.stock.'
          when v_tipo = 2 then 'Kardex inconsistente: la cadena de movimientos no cierra (stock_antes≠stock_despues del anterior). Renormalizar el libro mayor / re-anclar con auditoría.'
          when v_tipo = 4 then 'Producto sin re-conteo ni corte de auditoría → teórico no confiable; tomar/renovar conteo de almacén.'
          when v_dif > 0 then 'Sobrante en almacén vs último re-conteo + movimientos posteriores (ingreso sin movimiento / re-conteo desfasado).'
          else 'Faltante en almacén vs último re-conteo + movimientos posteriores (merma / salida sin movimiento / re-conteo desfasado).'
        end;

        insert into mos.stock_diferencias
          (ambito, zona_id, cod_barra, descripcion, real_qty, teorico_qty, diferencia, motivo_hipotesis, detalle, dia, detectado_ts, estado, tipo_error, tipo_etiqueta)
        values
          ('ALMACEN', '', r.cod, v_desc, r.realq, r.teorico, v_dif, v_hip,
           jsonb_build_object('saldoKardex', r.saldo_kardex, 'sinCorte', r.sin_corte,
                              'kardexGap', r.kardex_gap, 'stkUpd', r.stk_upd, 'kardexFecha', r.kardex_fecha,
                              'tieneAncla', r.tiene_ancla, 'anclaSaldo', r.ancla_saldo, 'anclaFecha', r.ancla_fecha),
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
           and coalesce(tipo_error,0) not in (3,5);
      end if;
    end loop;

    -- ── TIPO 3 · Salida-a-zona sin descuento de origen (filas-aviso) ──────────────────────────────────
    select (min(m.fecha) at time zone 'America/Lima')::date into v_era
      from wh.stock_movimientos m
     where m.tipo_operacion = 'CIERRE_GUIA' and m.origen like 'G%';
    v_era    := coalesce(v_era, v_dia - v_lb);
    v_t3from := greatest(v_era, v_dia - v_lb);

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

    -- ── TIPO 5 · Factor no configurado (filas-aviso) ──────────────────────────────────────────────────
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

  -- ══ FIX B (housekeeping) · purgar filas ABIERTAS de DÍAS ANTERIORES de los ámbitos reconciliados hoy ══
  --   Son diagnóstico re-derivable: lo vigente es la corrida de HOY. Preserva REVISADA y el día de hoy.
  --   Esto elimina la causa raíz de la repetición de un mismo producto en el listado (varios días ABIERTOS).
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
    'tipo3', v_n_t3, 'tipo5', v_n_t5,
    'total', v_n_zona + v_n_alm + v_n_t3 + v_n_t5);
end;
$function$;
revoke all on function mos.reconciliar_stock(jsonb) from public;
grant execute on function mos.reconciliar_stock(jsonb) to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- stock_diferencias_listar — FIX B · una sola fila por (ambito, zona_id, cod_barra): la del DÍA MÁS RECIENTE.
--   distinct on (...) order by dia desc → dedup robusto aunque queden filas de varios días en la tabla.
--   Mantiene filtros ambito/zona/estado/tipo y el orden final por |diferencia| desc.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.stock_diferencias_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
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
  -- DEDUP: una sola fila por (ambito, zona_id, cod_barra) → la del día más reciente (luego id desc).
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
           'tipoEtiqueta',    coalesce(v.tipo_etiqueta, mos._recon_tipo_etiqueta(v.tipo_error))
         ) order by abs(v.diferencia) desc, v.detectado_ts desc), '[]'::jsonb) into v_arr
    from vigentes v;

  return jsonb_build_object('ok', true, 'data',
           jsonb_build_object('total', jsonb_array_length(v_arr), 'items', v_arr))
         || mos._frescura_sombra();
end;
$function$;
revoke all on function mos.stock_diferencias_listar(jsonb) from public;
grant execute on function mos.stock_diferencias_listar(jsonb) to service_role, authenticated;
