-- 854e: la voz decía "5. soles" — to_char con FM deja el punto colgando en los montos enteros.
-- Se dice "5 soles" si es entero y "5 soles con 50" si tiene céntimos: así se entiende hablado.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='mos' and p.proname='yape_pendientes_anuncio';
  v_new := replace(v_def,
    $old$           'frase', case when monto is null then 'Llegó un Yape que no pude leer'
                         else trim(to_char(monto,'FM999990.99')) || ' soles' ||
                              case when coalesce(pagador,'') <> '' then ' de ' || pagador else '' end end$old$,
    $old$           'frase', case when monto is null then 'Llegó un Yape que no pude leer'
                         else trim(to_char(trunc(monto),'FM999999990')) || ' soles' ||
                              case when monto <> trunc(monto)
                                   then ' con ' || to_char(round((monto - trunc(monto)) * 100), 'FM90') else '' end ||
                              case when coalesce(pagador,'') <> '' then ' de ' || pagador else '' end end$old$);
  if v_new = v_def then raise exception '854e: no se encontró la frase'; end if;
  execute v_new;
end $mig$;
