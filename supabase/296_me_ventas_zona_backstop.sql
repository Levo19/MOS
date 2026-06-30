-- ============================================================================
-- 296_me_ventas_zona_backstop.sql — zona_id SIEMPRE poblada en me.ventas
-- ----------------------------------------------------------------------------
-- PROBLEMA: ~3.5% de ventas quedaban con zona_id NULL/'' (dispersas en el turno,
-- no solo el primer ticket). Causa: cuando la venta cae al camino de respaldo GAS
-- (_dualWriteVentaME en MigracionME.gs), ese upsert NO incluye zona_id (le falta el
-- mapeo en _ME_SPECS.ventas) → la columna queda vacía aunque la zona SÍ se conoce por
-- la caja. El camino directo (me.crear_venta_directa) sí la escribe; por eso es
-- intermitente. Impacto: esas ventas no entran a la comisión por zona ni a los reportes
-- por zona.
--
-- FIX (cero-GAS, una sola fuente, a prueba de balas): un trigger BEFORE INSERT/UPDATE
-- que, si zona_id llega vacío y hay id_caja, deriva la zona de me.cajas (que SIEMPRE la
-- tiene — verificado: 21/21 cajas con zona; 13/13 ventas sin zona eran recuperables).
-- Atrapa TODOS los caminos (directo, respaldo GAS, futuros) sin tocar GAS. No-destructivo:
-- si zona_id ya viene con valor, NO lo pisa.
-- ============================================================================

create or replace function me.tg_ventas_zona_backstop()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  -- Solo rellena si falta y hay caja de referencia. Nunca pisa una zona ya puesta.
  if coalesce(new.zona_id, '') = '' and coalesce(new.id_caja, '') <> '' then
    new.zona_id := (
      select zona_id from me.cajas
       where id_caja = new.id_caja and coalesce(zona_id, '') <> ''
       limit 1
    );
  end if;
  return new;
end;
$fn$;

drop trigger if exists tg_ventas_zona_backstop on me.ventas;
create trigger tg_ventas_zona_backstop
  before insert or update on me.ventas
  for each row execute function me.tg_ventas_zona_backstop();

-- Backfill de las ventas históricas sin zona cuya caja sí la tiene (recupera las 13).
update me.ventas v
   set zona_id = cj.zona_id
  from me.cajas cj
 where cj.id_caja = v.id_caja
   and coalesce(v.zona_id, '') = ''
   and coalesce(cj.zona_id, '') <> '';
