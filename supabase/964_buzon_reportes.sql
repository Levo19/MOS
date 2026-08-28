-- [964] Buzón Directo: reportes/dudas/capacitaciones de los admin al Master. Mensajería que se vuelve
-- ticket, con push DIRIGIDO (reporte→Master por rol; respuesta del Master→SOLO ese admin por nombre).
-- Categorías: rep (falla/regla) · ope (operativa) · con (consulta) · form (capacitación).

create table if not exists mos.buzon_tickets (
  id            bigserial primary key,
  codigo        text unique,
  categoria     text not null check (categoria in ('rep','ope','con','form')),
  titulo        text not null,
  campos        jsonb not null default '{}'::jsonb,   -- campos específicos por tipo (app, modulo, monto, dia/hora…)
  autor_nombre  text not null,
  autor_zona    text,
  autor_rol     text,
  estado        text not null default 'NUEVO' check (estado in ('NUEVO','VISTO','PROCESO','RESUELTO')),
  no_visto_master int not null default 1,   -- mensajes del admin que el Master no vio
  no_visto_autor  int not null default 0,   -- respuestas del Master que el admin no vio
  creado        timestamptz not null default now(),
  actualizado   timestamptz not null default now()
);
create index if not exists ix_buzon_estado on mos.buzon_tickets(estado, actualizado desc);
create index if not exists ix_buzon_autor  on mos.buzon_tickets(upper(autor_nombre), actualizado desc);

create table if not exists mos.buzon_mensajes (
  id         bigserial primary key,
  id_ticket  bigint not null references mos.buzon_tickets(id) on delete cascade,
  autor_tipo text not null check (autor_tipo in ('admin','master','sistema')),
  autor_nombre text,
  texto      text,
  media      jsonb not null default '[]'::jsonb,   -- [{tipo:'foto'|'video', path, cap}]
  creado     timestamptz not null default now()
);
create index if not exists ix_buzon_msg on mos.buzon_mensajes(id_ticket, creado);

-- catálogo legible por categoría (para textos de push)
create or replace function mos._buzon_cat_txt(c text) returns text language sql immutable as $$
  select case c when 'rep' then 'Falla/Regla' when 'ope' then 'Operativa'
                when 'con' then 'Consulta'    when 'form' then 'Capacitación' else c end;
$$;

-- ── ADMIN crea un ticket + primer mensaje → push al MASTER ──
create or replace function mos.buzon_crear(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_id bigint; v_cod text;
  v_cat text := nullif(btrim(coalesce(p->>'categoria','')),'');
  v_tit text := left(btrim(coalesce(p->>'titulo','')), 160);
  v_aut text := nullif(btrim(coalesce(p->>'autorNombre','')),'');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_cat is null or v_cat not in ('rep','ope','con','form') then return jsonb_build_object('ok',false,'error','categoría inválida'); end if;
  if v_tit = '' then return jsonb_build_object('ok',false,'error','falta el título'); end if;
  if v_aut is null then return jsonb_build_object('ok',false,'error','falta el autor'); end if;

  insert into mos.buzon_tickets(categoria, titulo, campos, autor_nombre, autor_zona, autor_rol)
  values (v_cat, v_tit, coalesce(p->'campos','{}'::jsonb), v_aut,
          nullif(btrim(coalesce(p->>'autorZona','')),''), nullif(btrim(coalesce(p->>'autorRol','')),''))
  returning id into v_id;
  v_cod := 'RPT-' || lpad(v_id::text, 4, '0');
  update mos.buzon_tickets set codigo = v_cod where id = v_id;

  insert into mos.buzon_mensajes(id_ticket, autor_tipo, autor_nombre, texto, media)
  values (v_id, 'admin', v_aut, nullif(btrim(coalesce(p->>'texto','')),''), coalesce(p->'media','[]'::jsonb));

  -- push DIRIGIDO al Master (por rol)
  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
      'titulo', '📮 ' || mos._buzon_cat_txt(v_cat) || ' · ' || v_aut,
      'cuerpo', v_tit,
      'data', jsonb_build_object('tipo','buzon','idTicket',v_id,'codigo',v_cod)));
  exception when others then null; end;

  return jsonb_build_object('ok',true,'data',jsonb_build_object('id',v_id,'codigo',v_cod));
end $function$;

-- ── responder (admin o master) → push DIRIGIDO al OTRO lado ──
create or replace function mos.buzon_responder(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_id bigint := nullif(p->>'idTicket','')::bigint;
  v_tipo text := nullif(btrim(coalesce(p->>'autorTipo','')),'');
  v_nom  text := nullif(btrim(coalesce(p->>'autorNombre','')),'');
  v_txt  text := nullif(btrim(coalesce(p->>'texto','')),'');
  v_media jsonb := coalesce(p->'media','[]'::jsonb);
  t mos.buzon_tickets%rowtype;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idTicket requerido'); end if;
  if v_tipo not in ('admin','master') then return jsonb_build_object('ok',false,'error','autorTipo inválido'); end if;
  if v_txt is null and jsonb_array_length(v_media) = 0 then return jsonb_build_object('ok',false,'error','mensaje vacío'); end if;
  select * into t from mos.buzon_tickets where id = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','ticket no existe'); end if;

  insert into mos.buzon_mensajes(id_ticket, autor_tipo, autor_nombre, texto, media)
  values (v_id, v_tipo, v_nom, v_txt, v_media);

  if v_tipo = 'master' then
    update mos.buzon_tickets set actualizado = now(),
           no_visto_autor = no_visto_autor + 1,
           estado = case when estado = 'NUEVO' then 'VISTO' else estado end
     where id = v_id;
    -- push SOLO al autor del ticket (por nombre)
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('usuarios', jsonb_build_array(upper(t.autor_nombre))),
        'titulo', '💬 El Master respondió · ' || t.codigo,
        'cuerpo', coalesce(v_txt, '📎 archivo'),
        'data', jsonb_build_object('tipo','buzon','idTicket',v_id,'codigo',t.codigo)));
    exception when others then null; end;
  else
    update mos.buzon_tickets set actualizado = now(), no_visto_master = no_visto_master + 1 where id = v_id;
    -- push al Master
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
        'titulo', '💬 ' || coalesce(v_nom, t.autor_nombre) || ' · ' || t.codigo,
        'cuerpo', coalesce(v_txt, '📎 archivo'),
        'data', jsonb_build_object('tipo','buzon','idTicket',v_id,'codigo',t.codigo)));
    exception when others then null; end;
  end if;

  return jsonb_build_object('ok',true,'data',jsonb_build_object('id',v_id));
end $function$;

-- ── master cambia estado → mensaje de sistema + push al autor ──
create or replace function mos.buzon_estado(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_id bigint := nullif(p->>'idTicket','')::bigint;
  v_est text := upper(nullif(btrim(coalesce(p->>'estado','')),''));
  t mos.buzon_tickets%rowtype; v_txt text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_est not in ('VISTO','PROCESO','RESUELTO','NUEVO') then return jsonb_build_object('ok',false,'error','estado inválido'); end if;
  select * into t from mos.buzon_tickets where id = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','ticket no existe'); end if;

  update mos.buzon_tickets set estado = v_est, actualizado = now(),
         no_visto_autor = case when v_est in ('PROCESO','RESUELTO') then no_visto_autor + 1 else no_visto_autor end
   where id = v_id;
  v_txt := case v_est when 'PROCESO' then 'El Master lo tomó: En proceso'
                      when 'RESUELTO' then 'El Master lo marcó Resuelto ✓'
                      when 'VISTO' then 'El Master lo vio' else 'Reabierto' end;
  insert into mos.buzon_mensajes(id_ticket, autor_tipo, texto) values (v_id, 'sistema', v_txt);

  if v_est in ('PROCESO','RESUELTO') then
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('usuarios', jsonb_build_array(upper(t.autor_nombre))),
        'titulo', '🛡️ Tu reporte ' || t.codigo,
        'cuerpo', v_txt, 'data', jsonb_build_object('tipo','buzon','idTicket',v_id,'codigo',t.codigo)));
    exception when others then null; end;
  end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('id',v_id,'estado',v_est));
end $function$;

-- ── marcar visto (limpia el contador del que mira) ──
create or replace function mos.buzon_visto(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_id bigint := nullif(p->>'idTicket','')::bigint; v_quien text := lower(coalesce(p->>'quien','')); begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_quien = 'master' then update mos.buzon_tickets set no_visto_master = 0, estado = case when estado='NUEVO' then 'VISTO' else estado end where id = v_id;
  else update mos.buzon_tickets set no_visto_autor = 0 where id = v_id; end if;
  return jsonb_build_object('ok',true);
end $function$;

-- ── lecturas: bandeja (master), mis tickets (admin), hilo completo, badge ──
create or replace function mos.buzon_bandeja(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v_cat text := nullif(btrim(coalesce(p->>'categoria','')),''); v_out jsonb; v_res jsonb; begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(row order by (estado='RESUELTO'), actualizado desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object('id',t.id,'codigo',t.codigo,'categoria',t.categoria,'titulo',t.titulo,
      'campos',t.campos,'autor',t.autor_nombre,'zona',coalesce(t.autor_zona,''),'rol',coalesce(t.autor_rol,''),
      'estado',t.estado,'noVisto',t.no_visto_master,
      'haceMin', round(extract(epoch from (now()-t.actualizado))/60)::int,
      'ultimo', (select coalesce(m.texto, case when jsonb_array_length(m.media)>0 then '📎 archivo' else '' end)
                   from mos.buzon_mensajes m where m.id_ticket=t.id order by m.creado desc limit 1)) as row,
      t.estado, t.actualizado
    from mos.buzon_tickets t
    where (v_cat is null or t.categoria = v_cat)
  ) z;
  select jsonb_build_object(
    'nuevos',(select count(*) from mos.buzon_tickets where estado='NUEVO'),
    'proceso',(select count(*) from mos.buzon_tickets where estado='PROCESO'),
    'resueltos',(select count(*) from mos.buzon_tickets where estado='RESUELTO'),
    'sinVer',(select coalesce(sum(no_visto_master),0) from mos.buzon_tickets)) into v_res;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('tickets',v_out,'resumen',v_res));
end $function$;

create or replace function mos.buzon_mis(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v_aut text := upper(nullif(btrim(coalesce(p->>'autorNombre','')),'')); v_out jsonb; begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_aut is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('tickets','[]'::jsonb)); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'codigo',t.codigo,'categoria',t.categoria,'titulo',t.titulo,
      'estado',t.estado,'noVisto',t.no_visto_autor,
      'haceMin', round(extract(epoch from (now()-t.actualizado))/60)::int,
      'ultimo',(select coalesce(m.texto,'📎 archivo') from mos.buzon_mensajes m where m.id_ticket=t.id order by m.creado desc limit 1))
      order by t.actualizado desc), '[]'::jsonb) into v_out
    from mos.buzon_tickets t where upper(t.autor_nombre) = v_aut;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('tickets',v_out));
end $function$;

create or replace function mos.buzon_ticket(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v_id bigint := nullif(p->>'idTicket','')::bigint; v_t jsonb; v_m jsonb; begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select to_jsonb(x) into v_t from (
    select id,codigo,categoria,titulo,campos,autor_nombre autor,autor_zona zona,autor_rol rol,estado,
           to_char(creado at time zone 'America/Lima','YYYY-MM-DD HH24:MI') creado
    from mos.buzon_tickets where id = v_id) x;
  if v_t is null then return jsonb_build_object('ok',false,'error','ticket no existe'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'tipo',m.autor_tipo,'nombre',coalesce(m.autor_nombre,''),
      'texto',coalesce(m.texto,''),'media',m.media,
      'hora',to_char(m.creado at time zone 'America/Lima','HH24:MI')) order by m.creado), '[]'::jsonb) into v_m
    from mos.buzon_mensajes m where m.id_ticket = v_id;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('ticket',v_t,'mensajes',v_m));
end $function$;

create or replace function mos.buzon_badge(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare v_n int; v_master boolean := coalesce((p->>'esMaster')::boolean,false);
  v_aut text := upper(nullif(btrim(coalesce(p->>'autorNombre','')),'')); begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_master then select coalesce(sum(no_visto_master),0) into v_n from mos.buzon_tickets;
  else select coalesce(sum(no_visto_autor),0) into v_n from mos.buzon_tickets where upper(autor_nombre) = coalesce(v_aut,'—'); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('n',coalesce(v_n,0)));
end $function$;

grant execute on function mos.buzon_crear(jsonb), mos.buzon_responder(jsonb), mos.buzon_estado(jsonb),
  mos.buzon_visto(jsonb), mos.buzon_bandeja(jsonb), mos.buzon_mis(jsonb), mos.buzon_ticket(jsonb),
  mos.buzon_badge(jsonb), mos._buzon_cat_txt(text) to authenticated, anon, service_role;

select '964 buzón listo' as ok;
