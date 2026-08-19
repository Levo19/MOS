-- [879] IA → GEMINI (19-ago-2026). Tarifario de Gemini para Gestión de IA, proveedor por config y
-- crones escalonados (cupo gratis = 5 req/min POR MODELO: tres crones en el mismo minuto se pisaban).
insert into mos.ia_precios (patron, etiqueta, usd_in, usd_out, usd_cache_w5, usd_cache_w1h, usd_cache_r, vigente_desde, fuente) values
  ('gemini-2.5-flash%',       'Gemini 2.5 Flash',        0.30, 2.50, 0, 0, 0.03,  '2026-08-19', 'ai.google.dev/pricing (tier gratis: $0)'),
  ('gemini-3.7-flash%',       'Gemini 3.7 Flash',        0.30, 2.50, 0, 0, 0.03,  '2026-08-19', 'estimado = 2.5 Flash (tier gratis: $0)'),
  ('gemini-3.5-flash%',       'Gemini 3.5 Flash',        0.30, 2.50, 0, 0, 0.03,  '2026-08-19', 'estimado = 2.5 Flash (tier gratis: $0)'),
  ('gemini-flash-latest%',    'Gemini Flash (latest)',   0.30, 2.50, 0, 0, 0.03,  '2026-08-19', 'estimado = 2.5 Flash (tier gratis: $0)'),
  ('gemini-%flash-lite%',     'Gemini Flash-Lite',       0.10, 0.40, 0, 0, 0.01,  '2026-08-19', 'ai.google.dev/pricing'),
  ('gemini-%pro%',            'Gemini Pro',              1.25, 10.00, 0, 0, 0.125, '2026-08-19', 'ai.google.dev/pricing')
on conflict do nothing;

insert into mos.config (clave, valor, descripcion) values
  ('IA_PROVEEDOR', 'gemini', 'Proveedor de IA de las Edge (ia, ocr-guia, descripcion-ia, sustitutos-ia): gemini | anthropic. Gemini con clave de AI Studio (tier gratis). Cambiar acá y en 60 s las Edge lo toman.')
on conflict (clave) do update set valor = excluded.valor, descripcion = excluded.descripcion;

-- crones escalonados (antes los tres a */10 en el MISMO minuto) y reactivados
select cron.alter_job(54, schedule := '3,13,23,33,43,53 * * * *', active := true);   -- descripcion-ia (2.5-flash + Google)
select cron.alter_job(58, schedule := '6,16,26,36,46,56 * * * *', active := true);   -- sustitutos-ia (2.5-flash + Google)
select cron.alter_job(63, schedule := '9,19,29,39,49,59 * * * *', active := true);   -- ocr guías (flash-latest, cupo propio)
select jobid, jobname, schedule, active from cron.job where jobid in (54,58,63) order by jobid;
