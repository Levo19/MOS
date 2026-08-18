-- 852b: el panel tiene que decir POR QUÉ falla la IA, no solo cuántas veces.
-- Al desplegar la contabilidad apareció de inmediato lo que el dueño venía sufriendo sin verlo:
-- "Your credit balance is too low to access the Anthropic API". Los tres crones siguen disparando
-- cada 10 minutos contra una cuenta sin saldo. Un contador de fallas no alcanza: hay que decir el
-- motivo en la cara, y traducirlo a algo accionable.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'mos' and p.proname = 'ia_uso_resumen';

  v_new := replace(v_def,
    $old$    'primerRegistro', (select to_char(min(dia),'YYYY-MM-DD') from mos.ia_uso)));$old$,
    $old$    'primerRegistro', (select to_char(min(dia),'YYYY-MM-DD') from mos.ia_uso),
    -- [852b] el motivo de falla más frecuente del período, ya traducido
    'fallaTop', (
      select jsonb_build_object(
               'n', f.n,
               'motivo', case
                 when f.err ilike '%credit balance is too low%' then 'SIN_SALDO'
                 when f.err ilike '%rate_limit%' or f.err ilike '% 429%' then 'LIMITE_TASA'
                 when f.err ilike '%overloaded%' or f.err ilike '% 529%' then 'ANTHROPIC_SATURADO'
                 when f.err ilike '%authentication%' or f.err ilike '% 401%' then 'API_KEY'
                 when f.err ilike '%timeout%' or f.err ilike '%abort%' then 'TIEMPO_AGOTADO'
                 else 'OTRO' end,
               'detalle', left(f.err, 220),
               'ultima', to_char(f.ult at time zone 'America/Lima','YYYY-MM-DD HH24:MI'))
        from (select coalesce(u.error,'') err, count(*) n, max(u.ts) ult
                from mos.ia_uso u
               where not u.ok and u.dia between v_desde and v_hoy and coalesce(u.error,'') <> ''
               group by 1 order by count(*) desc, max(u.ts) desc limit 1) f)));$old$);
  if v_new = v_def then raise exception '852b: no se encontró el cierre del resumen'; end if;
  execute v_new;
end $mig$;
