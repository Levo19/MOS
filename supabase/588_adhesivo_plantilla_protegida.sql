-- 588 · [Editor adhesivos] Las plantillas BASE (metadata.protegida=true) NO se eliminan — se
-- DUPLICAN (⎘) para crear una nueva editable/borrable. Guard server-side + el front oculta la 🗑.
create or replace function mos.adhesivo_plantilla_eliminar(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(p->>'idPlantilla','');
  v_prot boolean;
begin
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idPlantilla requerido'); end if;
  select coalesce((json #>> '{metadata,protegida}')::boolean, false) into v_prot
    from mos.adhesivo_plantillas where id_plantilla = v_id and activo;
  if coalesce(v_prot,false) then
    return jsonb_build_object('ok', false, 'error', 'PROTEGIDA',
      'detalle', 'Esta plantilla base no se puede eliminar. Duplícala (⎘) para crear una nueva.');
  end if;
  update mos.adhesivo_plantillas set activo = false where id_plantilla = v_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no encontrada: ' || v_id); end if;
  return jsonb_build_object('ok', true, 'eliminado', v_id);
end;
$fn$;
notify pgrst, 'reload schema';
