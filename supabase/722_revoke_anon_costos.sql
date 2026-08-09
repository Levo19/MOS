-- ════════════════════════════════════════════════════════════════════
-- 722 — DOCTRINA DE COSTOS/PRECIOS: quitar el acceso ANÓNIMO a las RPCs de costo.
--
-- DOCTRINA DEL DUEÑO: "los ÚNICOS que ponen costo son MOS (admin/master) y se
-- guardan en la tabla de costos; lo mismo precios. ME y WH solo hacen REGISTRO."
--
-- HALLAZGO DE LA AUDITORÍA (2026-08-08):
--   mos.quitar_costo_compra tenía GRANT EXECUTE a `anon`. Su único guard es
--   mos._claim_ok(), que es `me.jwt_app() in ('','MOS')` — y la anon key pública
--   (embebida en el front) produce jwt_app='' ⇒ PASA el guard.
--   Resultado: cualquiera con la anon key podía revertir por curl el costo que
--   una compra aplicó al catálogo, sin sesión ni identidad. Escritura de dinero
--   alcanzable sin autenticación = viola la doctrina.
--   El resto de las RPCs que escriben precio_costo/precio_venta ya estaban
--   correctamente limitadas a `authenticated` (anon=no).
--
-- CIERRE: revocar anon. `authenticated` se mantiene (es como entra MOS, cuyo
-- JWT lleva claim app='MOS' emitido por la Edge mint-mos).
-- Se incluye mos.cotejo_costos_guias (721, lectura): no hay razón para exponerla
-- a anónimos aunque no escriba.
--
-- NO se toca mos._claim_ok(): endurecerlo para rechazar el claim vacío es el
-- cierre de fondo, pero cambia el comportamiento de TODAS las RPCs mos.* a la
-- vez (impacto operativo) → queda reportado para decisión del dueño.
-- ════════════════════════════════════════════════════════════════════

-- ⚠ Revocar a `anon` NO basta: en Postgres toda función nace con EXECUTE para
--   PUBLIC, y has_function_privilege('anon',…) sigue dando true por herencia de
--   PUBLIC. Hay que revocar a AMBOS (medido en el ensayo begin/rollback).
revoke execute on function mos.quitar_costo_compra(jsonb)  from anon, public;
revoke execute on function mos.cotejo_costos_guias(jsonb)  from anon, public;
revoke execute on function mos.aplicar_costos_compra(jsonb) from public, anon;
revoke execute on function mos.actualizar_costo_sku(jsonb)  from public, anon;
revoke execute on function mos.actualizar_producto(jsonb)   from public, anon;
revoke execute on function mos.crear_producto(jsonb)        from public, anon;
revoke execute on function mos.actualizar_segmentos_precio(jsonb) from public, anon;
