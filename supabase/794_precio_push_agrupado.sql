-- 794_precio_push_agrupado.sql — [AUDITORÍA · FIX ALTO] un push por SENTENCIA, no por fila.
--
-- HALLAZGO: el trigger 791 `tg_precio_push` era FOR EACH ROW y `mos.emitir_push` hace un
-- `net.http_post` por invocación. Una carga masiva de precios (la herencia en cascada de
-- [777-779] tocó 32 filas de una) = 32 notificaciones a CADA tablet de ME, encima de la
-- pantalla de venta, más 32 filas en la cola de pg_net.
--
-- FIX (dos capas):
--  (1) STATEMENT-LEVEL con transition table → 1 push por sentencia. Si la sentencia trae
--      varias filas, el aviso dice "N precios actualizados" y el detalle vive en el modal
--      de ME (pestaña de 15 días). Si trae una sola, el mensaje detallado de siempre.
--  (2) VENTANA ANTI-RÁFAGA de 60 s (marca en mos.config): si el precio se carga fila por
--      fila (N sentencias separadas), el segundo y siguientes push dentro del minuto NO se
--      emiten. El operador ya fue avisado y la lista de 15 días tiene todo el detalle.
--
-- Se conserva TODO lo demás del 791: se ignoran migrados/SEED/cambios sin diferencia real,
-- y el cuerpo va envuelto en exception→null (un push jamás rompe el registro del precio).

create or replace function mos.tg_precio_push_stmt() returns trigger
language plpgsql security definer set search_path to ''
as $$
declare
  v_n      int;
  v_desc   text;
  v_val    numeric;
  v_ant    numeric;
  v_usr    text;
  v_sku    text;
  v_idp    text;
  v_tit    text;
  v_cuerpo text;
  v_ult    timestamptz;
begin
  begin
    -- Filas "reales" de esta sentencia (mismo criterio que 791).
    select count(*) into v_n
      from nuevas n
     where n.tipo = 'PRECIO'
       and coalesce(n.meta->>'migrado','') <> 'true'
       and upper(coalesce(n.source,'')) <> 'SEED'
       and (n.valor_anterior is null or n.valor <> n.valor_anterior);
    if coalesce(v_n,0) = 0 then return null; end if;

    -- (2) Ventana anti-ráfaga: máximo un push de precio por minuto.
    select nullif(valor,'')::timestamptz into v_ult
      from mos.config where clave = 'PRECIO_PUSH_ULTIMO' limit 1;
    if v_ult is not null and v_ult > now() - interval '60 seconds' then
      return null;   -- ya se avisó hace menos de un minuto; el detalle está en ME
    end if;

    if v_n = 1 then
      select n.valor, n.valor_anterior, n.usuario, n.sku_base, n.id_producto
        into v_val, v_ant, v_usr, v_sku, v_idp
        from nuevas n
       where n.tipo = 'PRECIO'
         and coalesce(n.meta->>'migrado','') <> 'true'
         and upper(coalesce(n.source,'')) <> 'SEED'
         and (n.valor_anterior is null or n.valor <> n.valor_anterior)
       limit 1;
      select descripcion into v_desc from mos.productos where id_producto = v_idp limit 1;
      v_desc := coalesce(nullif(btrim(v_desc),''), v_idp, v_sku, 'Producto');
      v_tit  := '🏷 Precio actualizado';
      v_cuerpo := v_desc ||
        case when v_ant is not null and v_ant > 0
             then ' · S/ ' || trim(to_char(v_ant,'FM99990.00')) || ' → S/ ' || trim(to_char(v_val,'FM99990.00'))
             else ' · precio S/ ' || trim(to_char(v_val,'FM99990.00')) end ||
        case when coalesce(v_usr,'') <> '' then ' · por ' || v_usr else '' end;
    else
      v_tit    := '🏷 ' || v_n || ' precios actualizados';
      v_cuerpo := 'Revisa la lista de cambios en Etiquetas de precio';
      v_sku    := '';
    end if;

    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('apps', jsonb_build_array('mosExpress')),
      'titulo', v_tit, 'cuerpo', v_cuerpo,
      'data', jsonb_build_object('tipo','etiqueta_nueva','skuBase', coalesce(v_sku,''), 'n', v_n)));

    insert into mos.config (clave, valor) values ('PRECIO_PUSH_ULTIMO', now()::text)
      on conflict (clave) do update set valor = excluded.valor;
  exception when others then
    null;   -- un push jamás rompe el registro del precio
  end;
  return null;
end;
$$;

drop trigger if exists tg_precio_push on mos.historial_precio_costo;   -- el FOR EACH ROW del 791
drop trigger if exists tg_precio_push_stmt on mos.historial_precio_costo;
create trigger tg_precio_push_stmt
  after insert on mos.historial_precio_costo
  referencing new table as nuevas
  for each statement execute function mos.tg_precio_push_stmt();
