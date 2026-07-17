-- 504 · get_medios_cobro robusto ante EMPRESA_MEDIOS_COBRO con JSON inválido (review 500x #4).
-- Antes: valor::jsonb tumbaba TODA la RPC si el texto no era JSON. Ahora se atrapa → devuelve [].
create or replace function me.get_medios_cobro()
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_medios jsonb;
begin
  begin
    select case when btrim(coalesce(valor,'')) = '' then '[]'::jsonb else valor::jsonb end
      into v_medios from mos.config where clave = 'EMPRESA_MEDIOS_COBRO';
  exception when others then v_medios := '[]'::jsonb;   -- valor corrupto → no tumbar la lectura
  end;
  return jsonb_build_object(
    'ok', true,
    'limite', coalesce((select valor from mos.config where clave='LIMITE_BANCARIZACION'),'2000'),
    'medios', coalesce(v_medios, '[]'::jsonb),
    'empresa', jsonb_build_object(
      'ruc',         (select empresa_ruc from fac.config where id=1),
      'razonSocial', (select empresa_razon_social from fac.config where id=1)));
end; $fn$;
revoke all on function me.get_medios_cobro() from public;
grant execute on function me.get_medios_cobro() to anon, authenticated, service_role;
