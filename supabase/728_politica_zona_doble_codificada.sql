-- 728 · DINERO: la politica_json de ZONA-01 estaba guardada como STRING con JSON adentro
-- (doble codificada) → politica_json->>'metaDiaria' devolvia NULL → _meta_zona/_comision_pct
-- caian al default global: meta 1500 (en vez de 4000) y comision 5% (en vez de 2.5%).
-- Efecto: la zona 01 alcanzaba "meta" con 2.7x menos venta y cobraba el DOBLE de comision.
update mos.zonas set politica_json = (politica_json #>> '{}')::jsonb where jsonb_typeof(politica_json) = 'string';
-- Raiz: actualizar_zona ignoraba el valor si no era objeto (por eso el string viejo sobrevivia).
-- Ahora lo desenvuelve al entrar. Ver definicion viva con [728].
