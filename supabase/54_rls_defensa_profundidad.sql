-- 54_rls_defensa_profundidad.sql — [FIX 40x · defensa en profundidad] Habilita RLS en las 2 tablas que quedaron sin él.
-- Auditoría global (2026-06-13): 73 tablas en mos/me/wh, 71 con RLS, 0 brechas explotables. Estas 2 NO tienen grant a
-- authenticated (no accesibles directo hoy), pero les falta RLS → si alguien les diera grant por error quedarían expuestas.
-- enable RLS (deny-all sin policy) NO rompe nada: las RPCs security definer corren como owner (bypassan RLS) y service_role
-- tiene bypassrls. Cierra la consistencia a 73/73 con RLS.

alter table me.correlativos_emitidos enable row level security;
alter table mos.dispositivo_zonas    enable row level security;
