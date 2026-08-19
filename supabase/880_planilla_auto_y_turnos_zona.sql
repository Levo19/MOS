-- [880] CRÉDITOS DE PERSONAL FIJO ≠ ASIGNAR (19-ago-2026)
-- Lo que vio Luis: en la mesa de créditos el ticket de SERGIO BAILON (personal fijo de WH, con
-- documento) ofrecía "👤 ASIGNAR", y el selector de turnos listaba también a los de almacén.
-- La regla original [848]: el selector es para TRABAJADORES DE ZONA (Z1/Z2, sin ficha); el personal
-- fijo con documento se descuenta SOLO en su liquidación (por cliente_doc, camino [572]).
--
-- 1) mos.turnos_del_dia: solo turnos DE ZONA (zona <> '') y sin documento en ficha. El personal
--    fijo desaparece del selector (en POS y en MOS, que usan la misma RPC).
-- 2) me.creditos_pendientes: nuevo campo `planillaAuto` = nombre del personal fijo cuyo documento
--    coincide con el cliente_doc del ticket (null si no aplica). El front lo usa para mostrar
--    "💼 planilla automática" en vez del botón ASIGNAR.
do $$
declare v_def text; v_old text; v_new text;
begin
  -- ── 1. turnos_del_dia ──
  v_def := pg_get_functiondef('mos.turnos_del_dia'::regproc);
  v_old := $q$       and upper(coalesce(l.rol,'')) not in ('MASTER','ADMIN','ADMINISTRADOR')$q$;
  if position(v_old in v_def) = 0 then raise exception 'turnos_del_dia: ancla no encontrada'; end if;
  v_new := $q$       and upper(coalesce(l.rol,'')) not in ('MASTER','ADMIN','ADMINISTRADOR')
       -- [880] SOLO trabajadores de zona: el personal fijo (WH, con documento) NO se asigna a mano,
       -- su consumo se descuenta solo en su liquidación por el documento del ticket [572].
       and coalesce(btrim(l.zona),'') <> ''
       and not exists (select 1 from mos.personal pf
                        where pf.id_personal = l.id_personal
                          and coalesce(btrim(pf.documento),'') <> '')$q$;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;

  -- ── 2. creditos_pendientes ──
  v_def := pg_get_functiondef('me.creditos_pendientes(integer)'::regprocedure);
  v_old := $q$      'estadoCobro',    vt.estado_cobro,$q$;
  if position(v_old in v_def) = 0 then raise exception 'creditos_pendientes: ancla no encontrada'; end if;
  v_new := $q$      -- [880] personal fijo: su documento en el ticket = se descuenta SOLO al liquidar (sin ASIGNAR)
      'planillaAuto', (select btrim(pf.nombre||' '||coalesce(pf.apellido,'')) from mos.personal pf
                        where pf.estado = true and coalesce(btrim(pf.documento),'') <> ''
                          and btrim(pf.documento) = btrim(coalesce(vt.cliente_doc,'')) limit 1),
      'estadoCobro',    vt.estado_cobro,$q$;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $$;

-- pruebas: el selector de hoy ya no lista almaceneros; el ticket de Sergio trae planillaAuto
select (select jsonb_agg(t->>'nombre') from jsonb_array_elements(mos.turnos_del_dia('{}'::jsonb)->'data'->'turnos') t) selector_hoy;
select t->>'correlativo' corr, t->>'planillaAuto' auto, t->'trabajador'->>'nombre' asignado
  from jsonb_array_elements(me.creditos_pendientes(30)->'data'->'grupos') g,
       jsonb_array_elements(g->'tickets') t
 where t->>'correlativo' in ('NVM2-000594','NVM2-000551','NVM2-000550','NVM2-000586','NVM2-000535') limit 8;
