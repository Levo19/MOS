-- 409 · FIX producción: despachos grandes de zona (50-60+ items) fallaban con "statement timeout".
-- Causa: el rol `authenticated` tiene statement_timeout=8s y las funciones de despacho NO lo sobrescribían.
-- Un despacho de zona con muchos ítems = N updates de stock + N kardex en un loop plpgsql; bajo cualquier
-- contención de lock (cajeros ME vendiendo los mismos productos, absorber del acumulador) supera los 8s →
-- la función lanza `canceling statement due to statement timeout` → su `exception when others` hace ROLLBACK
-- total → no queda guía, no se imprime ticket, no mueve stock (por eso el reintento "a veces" funciona: cuando
-- la contención baja termina en <8s). Son transacciones ATÓMICAS (all-or-nothing) → subir el timeout solo les
-- da margen para terminar; nunca hay commit parcial. 20s cubre despachos grandes bajo contención razonable.

alter function wh.crear_despacho_rapido(jsonb)      set statement_timeout = '20s';
alter function wh.cerrar_pickup_con_despacho(jsonb) set statement_timeout = '20s';
-- cerrar_guia_idempotente firma texto plano (p_id_guia text), no jsonb:
alter function wh.cerrar_guia_idempotente(text)     set statement_timeout = '20s';
