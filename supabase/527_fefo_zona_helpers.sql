-- 527_fefo_zona_helpers.sql — FASE 2 · FEFO por zona (revive el sistema que murió con el corte GAS)
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- HISTORIA: el consumo de lotes WH + la herencia de lotes a zona vivían en GAS cerrarGuia
-- (Guias.gs _consumirLotesFIFO + wh.propagar_lotes_zona_cierre). El cutover cero-GAS del cierre
-- (~2026-06-16) los dejó sin caller: los lotes WH dejaron de consumirse (drift 161 productos /
-- ~52k uds), me.zona_lotes dejó de recibir (último 2026-06-18) y la rotación en zona (RIZ Capa 5)
-- NUNCA se cableó (0 consumos históricos). Esta fase porta TODO al server:
--   527 (este): helpers FEFO + fix de gate + trigger de ventas + vencimientos_lista con zona.
--   528: hooks en los 3 cierres (wh.cerrar_guia_idempotente, wh.crear_despacho_rapido,
--        me.cerrar_guia_zona_idempotente) — SIEMPRE blindados: el libro de lotes jamás tumba dinero.
--   529: reconciliación one-time del drift (FEFO).

-- ── A) Consumo FEFO de lotes WH (vence primero, sale primero). Interno (sin gate propio:
--       lo llaman solo funciones security-definer de cierre; sin grant a authenticated).
--       Devuelve las asignaciones [{idLote,codBarra,skuBase,fechaVencimiento,cantidad}] para
--       heredarlas a la zona. Escribe wh.lotes_historial (¡por fin con escritor!).
create or replace function wh._consumir_lotes_fefo(
  p_cod text, p_cant numeric, p_ref text, p_motivo text, p_usuario text default 'sistema')
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_rest numeric := p_cant;
  v_take numeric;
  v_sku  text;
  v_out  jsonb := '[]'::jsonb;
  r      record;
begin
  if p_cod is null or coalesce(p_cant,0) <= 0 then return v_out; end if;
  select nullif(btrim(sku_base),'') into v_sku
    from mos.productos where upper(codigo_barra) = upper(p_cod) limit 1;
  for r in
    select id_lote, cantidad_actual, fecha_vencimiento
      from wh.lotes_vencimiento
     where upper(cod_producto) = upper(p_cod)
       and estado = 'ACTIVO' and coalesce(cantidad_actual,0) > 0
     order by fecha_vencimiento asc nulls last, fecha_creacion asc nulls last, id_lote asc
     for update
  loop
    exit when v_rest <= 0;
    v_take := least(r.cantidad_actual, v_rest);
    update wh.lotes_vencimiento
       set cantidad_actual = cantidad_actual - v_take,
           estado = case when cantidad_actual - v_take <= 0 then 'AGOTADO' else 'ACTIVO' end
     where id_lote = r.id_lote;
    insert into wh.lotes_historial (id_hist, ts, id_lote, cod_producto, id_guia, accion, cantidad, motivo, usuario)
    values ('LH_'||coalesce(p_ref,'x')||'#'||r.id_lote, now(), r.id_lote, p_cod,
            coalesce(p_ref,''), 'CONSUMO', v_take, coalesce(p_motivo,'FEFO'), coalesce(p_usuario,'sistema'))
    on conflict (id_hist) do nothing;
    v_out := v_out || jsonb_build_object(
      'idLote', r.id_lote, 'codBarra', p_cod, 'skuBase', coalesce(v_sku,''),
      'fechaVencimiento', case when r.fecha_vencimiento is null then ''
        else to_char(r.fecha_vencimiento at time zone 'America/Lima','YYYY-MM-DD') end,
      'cantidad', v_take);
    v_rest := v_rest - v_take;
  end loop;
  return v_out;   -- lo no cubierto por lotes = huérfano (stock pre-lotes) — informativo, no error
end; $fn$;
revoke execute on function wh._consumir_lotes_fefo(text,numeric,text,text,text) from public, anon, authenticated;

-- ── B) Consumo FEFO del libro de lotes de ZONA por código de barras (ventas / salida a jefa /
--       devolución a WH / traslado-out). Match directo por cod_barras; si el vendido es una
--       PRESENTACIÓN (otro código), cae a sku_base × factor (aproximación informativa — el libro
--       de zona no es dinero). Devuelve aplicados[] para heredar en traslados. Interno (sin grant).
create or replace function me.zona_consumir_fefo_cod(
  p_zona text, p_cod text, p_cant numeric, p_ref text default '')
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_zona text := upper(btrim(coalesce(p_zona,'')));
  v_cod  text := upper(btrim(coalesce(p_cod,'')));
  v_rest numeric := p_cant;
  v_take numeric;
  v_cons numeric := 0;
  v_apl  jsonb := '[]'::jsonb;
  v_sku  text; v_tipo text; v_factor numeric;
  r      record;
begin
  if v_zona = '' or v_cod = '' or coalesce(p_cant,0) <= 0 then
    return jsonb_build_object('ok',false,'error','PARAMS'); end if;

  -- Ronda 1: match directo por cod_barras (el caso normal: la zona recibió ese código)
  for r in
    select id_lote, cant_restante, sku_base, fecha_vencimiento from me.zona_lotes
     where zona_id = v_zona and upper(coalesce(cod_barras,'')) = v_cod and coalesce(cant_restante,0) > 0
     order by fecha_vencimiento asc nulls last, fecha_ingreso asc nulls last, id_lote asc
     for update
  loop
    exit when v_rest <= 0;
    v_take := least(r.cant_restante, v_rest);
    update me.zona_lotes
       set cant_restante = cant_restante - v_take,
           estado = case when cant_restante - v_take <= 0 then 'AGOTADO' else 'ACTIVO' end
     where zona_id = v_zona and id_lote = r.id_lote and upper(coalesce(cod_barras,'')) = v_cod;
    v_cons := v_cons + v_take; v_rest := v_rest - v_take;
    v_apl := v_apl || jsonb_build_object('idLote', r.id_lote, 'codBarra', p_cod,
      'skuBase', coalesce(r.sku_base,''), 'cantidad', v_take,
      'fechaVencimiento', case when r.fecha_vencimiento is null then ''
        else to_char(r.fecha_vencimiento at time zone 'America/Lima','YYYY-MM-DD') end);
  end loop;

  -- Ronda 2: presentación de otro código → mapear a sku_base con factor de conversión
  if v_rest > 0 then
    select nullif(btrim(sku_base),''), coalesce(tipo_producto,''), coalesce(nullif(factor_conversion,0),1)
      into v_sku, v_tipo, v_factor
      from mos.productos where upper(codigo_barra) = v_cod limit 1;
    if v_sku is not null then
      if v_tipo ilike '%PRESENTACION%' then v_rest := v_rest * v_factor; end if;
      for r in
        select id_lote, cant_restante, sku_base, cod_barras, fecha_vencimiento from me.zona_lotes
         where zona_id = v_zona and sku_base = v_sku and coalesce(cant_restante,0) > 0
         order by fecha_vencimiento asc nulls last, fecha_ingreso asc nulls last, id_lote asc
         for update
      loop
        exit when v_rest <= 0;
        v_take := least(r.cant_restante, v_rest);
        update me.zona_lotes
           set cant_restante = cant_restante - v_take,
               estado = case when cant_restante - v_take <= 0 then 'AGOTADO' else 'ACTIVO' end
         where zona_id = v_zona and id_lote = r.id_lote and sku_base = v_sku;
        v_cons := v_cons + v_take; v_rest := v_rest - v_take;
        v_apl := v_apl || jsonb_build_object('idLote', r.id_lote, 'codBarra', coalesce(r.cod_barras,''),
          'skuBase', v_sku, 'cantidad', v_take,
          'fechaVencimiento', case when r.fecha_vencimiento is null then ''
            else to_char(r.fecha_vencimiento at time zone 'America/Lima','YYYY-MM-DD') end);
      end loop;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'consumido', v_cons,
    'huerfano', greatest(v_rest, 0), 'aplicados', v_apl, 'ref', coalesce(p_ref,''));
end; $fn$;
revoke execute on function me.zona_consumir_fefo_cod(text,text,numeric,text) from public, anon, authenticated;

-- ── C) FIX de gate: me.zona_recibir_lote exigía mos._claim_ok ('' o 'MOS') — las llamadas
--       internas desde los cierres (claims 'warehouseMos'/'mosExpress') morían en silencio.
--       En la era GAS todo entraba como service_role (''), por eso funcionaba. Superset seguro.
--       (Solo se cambia el gate; el resto de la función queda intacto vía redefinición dinámica.)
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'zona_recibir_lote';
  v_src := replace(v_src,
    'if not mos._claim_ok() then',
    'if not (mos._claim_ok() or wh._claim_ok() or me._claim_zona_ok()) then');
  execute v_src;
end $$;

-- ── D) TRIGGER de VENTAS → rotación FEFO en zona. Blindado total: el libro de lotes JAMÁS
--       tumba una venta (dinero). Zona derivada de me.ventas.zona_id (procesar_venta la llena).
create or replace function me._tg_zona_lotes_venta()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare v_zona text;
begin
  begin
    select upper(nullif(btrim(coalesce(zona_id,'')),'')) into v_zona
      from me.ventas where id_venta = new.id_venta limit 1;
    if v_zona is not null and coalesce(new.cantidad,0) > 0
       and coalesce(btrim(coalesce(new.cod_barras,'')),'') <> '' then
      perform me.zona_consumir_fefo_cod(v_zona, new.cod_barras, new.cantidad, 'venta '||new.id_venta);
    end if;
  exception when others then null;
  end;
  return new;
end; $fn$;
drop trigger if exists tg_zona_lotes_venta on me.ventas_detalle;
create trigger tg_zona_lotes_venta
  after insert on me.ventas_detalle
  for each row execute function me._tg_zona_lotes_venta();

-- ── E) wh.vencimientos_lista v2: alcance ZONA. p.zona → lee me.zona_lotes de esa zona con el
--       MISMO semáforo (VENCIDO/CRÍTICO/ALERTA/URGENTE/SANO). Sin p.zona → almacén (WH lotes).
create or replace function wh.vencimientos_lista(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select case when wh._claim_ok() or mos._claim_ok() or me._claim_zona_ok()
    then (
      with cfg as (
        select coalesce((select valor::int from wh.config where clave='DIAS_ALERTA_VENC_CRITICO'), 7)  as crit,
               coalesce((select valor::int from wh.config where clave='DIAS_ALERTA_VENC'), 30)         as alerta,
               coalesce((select valor::int from wh.config where clave='DIAS_ALERTA_VENC_URGENTE'), 90) as urgente
      ),
      lotes as (
        select l.id_lote, l.cod_producto, l.fecha_vencimiento, l.cantidad_actual, l.id_guia,
               ((l.fecha_vencimiento at time zone 'America/Lima')::date
                 - (now() at time zone 'America/Lima')::date) as dias
          from wh.lotes_vencimiento l
         where nullif(btrim(coalesce(p->>'zona','')),'') is null
           and l.estado = 'ACTIVO' and coalesce(l.cantidad_actual,0) > 0
           and l.fecha_vencimiento is not null
        union all
        select z.id_lote, coalesce(nullif(z.cod_barras,''), z.sku_base), z.fecha_vencimiento,
               z.cant_restante, coalesce(z.id_guia_origen,''),
               ((z.fecha_vencimiento at time zone 'America/Lima')::date
                 - (now() at time zone 'America/Lima')::date) as dias
          from me.zona_lotes z
         where nullif(btrim(coalesce(p->>'zona','')),'') is not null
           and z.zona_id = upper(btrim(p->>'zona'))
           and coalesce(z.cant_restante,0) > 0
           and z.fecha_vencimiento is not null
      )
      select jsonb_build_object('ok', true,
        'umbrales', (select jsonb_build_object('critico',crit,'alerta',alerta,'urgente',urgente) from cfg),
        'zona', coalesce(nullif(btrim(coalesce(p->>'zona','')),''),'ALMACEN'),
        'data', coalesce((
          select jsonb_agg(jsonb_build_object(
            'idLote', lo.id_lote,
            'codigoProducto', lo.cod_producto,
            'fechaVencimiento', to_char(lo.fecha_vencimiento at time zone 'America/Lima', 'YYYY-MM-DD'),
            'cantidadActual', lo.cantidad_actual,
            'idGuia', coalesce(lo.id_guia,''),
            'diasRestantes', lo.dias,
            'severidad', case
              when lo.dias < 0 then 'VENCIDO'
              when lo.dias <= (select crit from cfg) then 'CRITICO'
              when lo.dias <= (select alerta from cfg) then 'ALERTA'
              when lo.dias <= (select urgente from cfg) then 'URGENTE'
              else 'SANO' end
          ) order by lo.dias asc)
          from lotes lo), '[]'::jsonb))
    )
    else jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA') end;
$fn$;
grant execute on function wh.vencimientos_lista(jsonb) to authenticated;
