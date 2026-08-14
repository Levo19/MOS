-- 786 · FIX 403: me.reabrir_guia_zona sin grant a authenticated (14-ago-2026).
-- La RPC existía con guards correctos (reverificar_clave_admin estricto + _claim_zona_ok)
-- pero solo tenía EXECUTE para postgres/service_role → el POS recibía 403 Forbidden.
-- Bug latente invisible: desde el rediseño del historial (v2.8.39, overlay z-70) el
-- teclado de clave se abría DETRÁS (z-60) y nadie llegaba a disparar la RPC. Al arreglar
-- el z-index (2.8.288) el 403 afloró. Mismo grant que editar_guia_cabecera/lineas.
grant execute on function me.reabrir_guia_zona(jsonb) to authenticated;
