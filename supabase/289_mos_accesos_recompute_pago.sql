-- ============================================================================
-- 289_mos_accesos_recompute_pago.sql — FASE 2: motor de PAGO en vivo (server-side)
-- ----------------------------------------------------------------------------
-- Calcula los AUTOS del jornal (pago_envasado + comisión bono_meta + KPIs) desde la
-- actividad real (wh.envasados / me.ventas / wh.auditorias) con las fórmulas EXACTAS
-- confirmadas por el dueño, PRESERVANDO lo manual (bonificacion/sancion/estado/id_pago).
--
-- MODELO (confirmado 2026-06-29):
--   · Vendedor/Cajero = FIJO (config evalFijo*, default 50) + COMISIÓN 5% AUTOMÁTICA:
--       pool_zona  = comisionPct% × max(0, venta_cobrada_zona − metaDiaria_zona)
--       comisión_i = pool_zona × (venta_cobrada_i / venta_cobrada_zona)
--     comisionPct + metaDiaria salen de mos.zonas.politica_json (fallback config).
--     venta_cobrada = Σ total de ventas EFECTIVO+VIRTUAL+MIXTO (sin crédito/anuladas).
--     NO requiere auditoría (automática). Reemplaza el bono fijo 8/15.
--   · Envasador  = unidades_envasadas × tarifa_envasado (config 0.10). Sin fijo.
--   · Almacenero = fijo (monto_base) + envasado.
--   · El admin suma/resta en la auditoría diaria → bonificacion/sancion: SE PRESERVAN.
--   total_dia = max(0, monto_base + pago_envasado + bono_meta + bonificacion − sancion)
--
-- ⚠️ INERTE: gateado por MOS_ACCESOS_DIRECTO. Idempotente. NO crea filas (solo recalcula
--    las que ya existen por el login). MASTER/ADMIN: skip.
-- ⚠️ ANTI-FLAPPING: al ACTIVAR, GAS debe dejar de upsertear bono_meta con el modelo viejo
--    (8/15) — agregar 'liquidaciones_dia' a MOS_SYNC_OFF_TABLAS. Documentado en el doc.
-- ============================================================================

-- 0) Config del fijo de vendedor/cajero (editable; el dueño puede cambiarlo a futuro).
insert into mos.config (clave, valor, descripcion) values
  ('evalFijoVendedor','50','Fijo diario del VENDEDOR ME (S/). Editable.'),
  ('evalFijoCajero','50','Fijo diario del CAJERO ME (S/). Editable.')
on conflict (clave) do nothing;

-- 1) Normalizador de nombres (sin extensión unaccent): trim + colapsar espacios +
--    minúsculas + quitar tildes/ñ. Para cruzar actividad (que se llavea por NOMBRE)
--    con la persona.
create or replace function mos._norm_nom(t text)
returns text language sql immutable set search_path = '' as $fn$
  select lower(btrim(regexp_replace(
    translate(coalesce(t,''),
      'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ',
      'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC'),
    '\s+',' ','g')));
$fn$;
revoke all on function mos._norm_nom(text) from public;
grant execute on function mos._norm_nom(text) to service_role;

-- 2) _fijo_personal: ahora con fallback a config evalFijo<Rol> (vendedor sin plantilla).
create or replace function mos._fijo_personal(p_id_personal text, p_rol text)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(
    (select monto_base from mos.personal
      where id_personal = p_id_personal and monto_base is not null limit 1),
    (select monto_base from mos.personal
      where upper(coalesce(rol,'')) = upper(coalesce(p_rol,''))
        and monto_base is not null and coalesce(estado,false) = true
      order by monto_base desc limit 1),
    mos._numn((select valor from mos.config
                where clave = 'evalFijo' || initcap(lower(coalesce(p_rol,''))) limit 1)),
    0::numeric);
$fn$;
revoke all on function mos._fijo_personal(text,text) from public;
grant execute on function mos._fijo_personal(text,text) to service_role;

-- 3) helpers de política de zona (con fallback a config global).
create or replace function mos._meta_zona(p_zona text)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(
    -- [100x · C1] match normalizado (case/espacios) como el resto del código (RIZ 128). Con match
    -- exacto, una zona guardada como 'zona-02'/'ZONA-02 ' no casaba → meta=0 → comisión sobre TODA
    -- la venta de zona sin umbral = sobre-pago invisible. Hoy casan exacto, esto lo blinda.
    mos._numn((select politica_json->>'metaDiaria' from mos.zonas where upper(btrim(id_zona)) = upper(btrim(p_zona)) limit 1)),
    mos._numn((select valor from mos.config where clave='evalMetaCajero' limit 1)),
    0::numeric);
$fn$;
create or replace function mos._comision_pct(p_zona text)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(
    mos._numn((select politica_json->>'comisionExcedentePct' from mos.zonas where upper(btrim(id_zona)) = upper(btrim(p_zona)) limit 1)),
    mos._numn((select valor from mos.config where clave='evalComisionExcedentePct' limit 1)),
    0::numeric);
$fn$;
revoke all on function mos._meta_zona(text)    from public;
revoke all on function mos._comision_pct(text) from public;
grant execute on function mos._meta_zona(text)    to service_role;
grant execute on function mos._comision_pct(text) to service_role;

-- 4) venta cobrada de una persona (por nombre) en una zona/día. EFECTIVO+VIRTUAL+MIXTO,
--    sin crédito/por_cobrar/anuladas (que no empiezan con esos métodos).
create or replace function mos._venta_cobrada_persona(p_nombre text, p_zona text, p_dia date)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(sum(v.total),0)::numeric
    from me.ventas v
   where (v.fecha at time zone 'America/Lima')::date = p_dia
     and coalesce(v.zona_id,'') = coalesce(p_zona,'')
     and mos._norm_nom(v.vendedor) = mos._norm_nom(p_nombre)
     and v.forma_pago ~* '^(efectivo|virtual|mixto)';
$fn$;
create or replace function mos._venta_cobrada_zona(p_zona text, p_dia date)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(sum(v.total),0)::numeric
    from me.ventas v
   where (v.fecha at time zone 'America/Lima')::date = p_dia
     and coalesce(v.zona_id,'') = coalesce(p_zona,'')
     and v.forma_pago ~* '^(efectivo|virtual|mixto)';
$fn$;
revoke all on function mos._venta_cobrada_persona(text,text,date) from public;
revoke all on function mos._venta_cobrada_zona(text,date)        from public;
grant execute on function mos._venta_cobrada_persona(text,text,date) to service_role;
grant execute on function mos._venta_cobrada_zona(text,date)        to service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5) mos.recomputar_dia(p {idPersonal, fecha}) — recalcula los AUTOS de UNA fila.
--    Preserva bonificacion/sancion/estado/id_pago + columnas de asistencia.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function mos.recomputar_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_id_dia  text;
  v_dia     date;
  r         mos.liquidaciones_dia%rowtype;
  v_rol     text;
  v_nomfull text;
  v_zona    text;
  v_fijo    numeric;
  v_tarifa  numeric;
  v_prod    numeric := 0;
  v_pagoenv numeric := 0;
  v_vcob    numeric := 0;
  v_vzona   numeric := 0;
  v_meta    numeric := 0;
  v_pct     numeric := 0;
  v_pool    numeric := 0;
  v_bono    numeric := 0;
  v_prog    numeric := 0;
  v_aud     numeric := 0;
  v_metaaud numeric;
  v_total   numeric;
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ACCESOS_DIRECTO_OFF');
  end if;
  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
  begin v_dia := v_fecha_s::date; exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;

  select * into r from mos.liquidaciones_dia where id_dia = v_id_dia for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_EXISTE','skipped',true); end if;

  v_rol := upper(coalesce(r.rol,''));
  if v_rol in ('MASTER','ADMIN','ADMINISTRADOR') then
    return jsonb_build_object('ok',true,'skipped','ROL_BLOQUEADO');
  end if;

  v_zona    := coalesce(r.zona,'');
  v_fijo    := mos._fijo_personal(v_idp, v_rol);
  v_tarifa  := coalesce(mos._numn((select valor from mos.config where clave='tarifa_envasado' limit 1)),0.10);
  v_metaaud := coalesce(mos._numn((select valor from mos.config where clave='evalMetaAuditorias' limit 1)),0);
  -- nombre canónico: persona real (nombre+apellido) o el nombre de la fila (temporal ME)
  v_nomfull := coalesce((select btrim(nombre||' '||coalesce(apellido,'')) from mos.personal where id_personal = v_idp limit 1),
                        r.nombre);

  if v_rol in ('ENVASADOR','ALMACENERO') then
    -- pago por envasado: unidades producidas (no anuladas) × tarifa
    select coalesce(sum(unidades_producidas),0) into v_prod
      from wh.envasados
     where (fecha at time zone 'America/Lima')::date = v_dia
       and upper(coalesce(estado,'')) <> 'ANULADO'
       and mos._norm_nom(usuario) = mos._norm_nom(v_nomfull);
    v_pagoenv := round(coalesce(v_prod,0) * v_tarifa, 2);
    v_bono := 0;
    -- auditorías ejecutadas en almacén
    select count(*) into v_aud from wh.auditorias
     where (coalesce(fecha_ejecucion, fecha_asignacion) at time zone 'America/Lima')::date = v_dia
       and upper(coalesce(estado,'')) in ('EJECUTADA','COMPLETADA','OK')
       and mos._norm_nom(usuario) = mos._norm_nom(v_nomfull);

  elsif v_rol in ('CAJERO','VENDEDOR') then
    -- [ext · identidad NOMBRE|ZONA] La fila YA ES por zona (Sergio|ZONA-01 vs Sergio|ZONA-02)
    -- → se usa r.zona directo, cada fila cobra su zona. FALLBACK (filas viejas MEX:nombre sin
    -- zona o pulso vacío): derivar la zona dominante de me.ventas (con tiebreaker H1).
    v_zona := nullif(btrim(coalesce(r.zona,'')), '');
    if v_zona is null then
      select v.zona_id into v_zona
        from me.ventas v
       where (v.fecha at time zone 'America/Lima')::date = v_dia
         and mos._norm_nom(v.vendedor) = mos._norm_nom(v_nomfull)
         and v.forma_pago ~* '^(efectivo|virtual|mixto)'
         and coalesce(v.zona_id,'') <> ''
       group by v.zona_id order by sum(v.total) desc, v.zona_id asc limit 1;
    end if;
    v_zona := coalesce(v_zona, '');
    -- comisión 5% del excedente de zona, proporcional a lo cobrado por la persona
    v_vcob  := mos._venta_cobrada_persona(v_nomfull, v_zona, v_dia);
    v_vzona := mos._venta_cobrada_zona(v_zona, v_dia);
    v_meta  := mos._meta_zona(v_zona);
    v_pct   := mos._comision_pct(v_zona);
    v_pool  := round(greatest(0::numeric, v_vzona - v_meta) * v_pct / 100.0, 2);
    v_bono  := case when v_vzona > 0 then round(v_pool * (v_vcob / v_vzona), 2) else 0 end;
    v_prog  := case when v_meta > 0 then round(v_vcob / v_meta * 100, 1) else 0 end;
    v_pagoenv := 0; v_prod := 0;
    -- auditorías de ventas (ME) ejecutadas
    select count(*) into v_aud from me.auditorias
     where (fecha at time zone 'America/Lima')::date = v_dia
       and mos._norm_nom(vendedor) = mos._norm_nom(v_nomfull);
  else
    v_pagoenv := 0; v_bono := 0;
  end if;

  -- total preservando lo manual (bonificacion/sancion ya en la fila)
  v_total := mos._liqdia_total(v_fijo, v_pagoenv, v_bono, coalesce(r.bonificacion,0), coalesce(r.sancion,0));

  update mos.liquidaciones_dia set
      monto_base          = v_fijo,
      pago_envasado       = v_pagoenv,
      bono_meta           = v_bono,
      tarifa_envasado     = v_tarifa,
      productos_envasados = coalesce(v_prod,0),
      venta_cobrada       = coalesce(v_vcob,0),
      venta_zona          = coalesce(v_vzona,0),
      meta_zona           = coalesce(v_meta,0),
      progreso_venta_pct  = coalesce(v_prog,0),
      auditorias_hechas   = coalesce(v_aud,0),
      meta_auditorias     = case when v_metaaud > 0 then v_metaaud else meta_auditorias end,
      cumplio_auditorias  = (coalesce(v_aud,0) >= case when v_metaaud>0 then v_metaaud else coalesce(meta_auditorias,0) end),
      -- persiste la zona derivada (cajero/vendedor); no blanquea una zona existente
      zona                = coalesce(nullif(btrim(coalesce(v_zona,'')), ''), zona),
      total_dia           = v_total,
      ts_actualizado      = now()
    where id_dia = v_id_dia;

  return jsonb_build_object('ok',true,'idDia',v_id_dia,'rol',v_rol,
    'montoBase',v_fijo,'pagoEnvasado',v_pagoenv,'bonoMeta',v_bono,
    'ventaCobrada',v_vcob,'ventaZona',v_vzona,'auditorias',v_aud,'totalDia',v_total);
end;
$fn$;
revoke all on function mos.recomputar_dia(jsonb) from public;
grant execute on function mos.recomputar_dia(jsonb) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6) mos.recomputar_zona_dia(p {zona, fecha}) — recalcula TODAS las filas de POS de
--    una zona/día (la comisión de cada uno depende de la venta total de la zona).
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function mos.recomputar_zona_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona    text := btrim(coalesce(p->>'zona',''));
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_dia     date;
  v_n int := 0;
  rec record;
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ACCESOS_DIRECTO_OFF');
  end if;
  if v_fecha_s is null then return jsonb_build_object('ok',false,'error','fecha requerida'); end if;
  begin v_dia := v_fecha_s::date; exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;

  for rec in
    select id_personal from mos.liquidaciones_dia
     where (fecha at time zone 'America/Lima')::date = v_dia
       and coalesce(zona,'') = v_zona
       and upper(coalesce(rol,'')) in ('CAJERO','VENDEDOR')
  loop
    perform mos.recomputar_dia(jsonb_build_object('idPersonal',rec.id_personal,'fecha',v_fecha_s));
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok',true,'zona',v_zona,'fecha',v_dia,'recalculadas',v_n);
end;
$fn$;
revoke all on function mos.recomputar_zona_dia(jsonb) from public;
grant execute on function mos.recomputar_zona_dia(jsonb) to authenticated, service_role;
