CREATE OR REPLACE FUNCTION mos._validar_segmentos_precio(segs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_n     int;
  v_i     int;
  v_s     jsonb;
  v_min   numeric;
  v_max   numeric;   -- null = infinito
  v_aj    numeric;
  v_minc  boolean;
  v_maxc  boolean;
  v_limpios jsonb := '[]'::jsonb;
  v_seg   jsonb;
  -- para la detección de solapamiento
  v_a jsonb; v_b jsonb;
  v_amax numeric; v_bmax numeric;   -- null = +infinito (Infinity de GAS)
  v_amin numeric; v_bmin numeric;
  v_amaxc boolean; v_amincl boolean; v_bmaxc boolean; v_bmincl boolean;
  v_solapan boolean;
  v_ia int; v_ib int;
begin
  if segs is null or jsonb_typeof(segs) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'Debe ser un array');
  end if;
  v_n := jsonb_array_length(segs);
  if v_n = 0 then return jsonb_build_object('ok', true, 'segmentos', '[]'::jsonb); end if;

  -- 1) validar + limpiar cada segmento (índices base-0 como el for de GAS; mensajes "Segmento N" 1-based)
  for v_i in 0 .. v_n - 1 loop
    v_s := segs -> v_i;
    -- min: number >= 0
    v_min := case when jsonb_typeof(v_s->'min') = 'number' then (v_s->>'min')::numeric else null end;
    if v_min is null or v_min < 0 then
      return jsonb_build_object('ok', false, 'error', 'Segmento '||(v_i+1)||': min debe ser número >= 0');
    end if;
    -- max: null (infinito) o number > min
    if (v_s->'max') is null or jsonb_typeof(v_s->'max') = 'null' then
      v_max := null;
    elsif jsonb_typeof(v_s->'max') = 'number' then
      v_max := (v_s->>'max')::numeric;
      if v_max <= v_min then
        return jsonb_build_object('ok', false, 'error', 'Segmento '||(v_i+1)||': max debe ser > min (o null para infinito)');
      end if;
    else
      return jsonb_build_object('ok', false, 'error', 'Segmento '||(v_i+1)||': max debe ser > min (o null para infinito)');
    end if;
    -- ajustePct: number, ≠0, sin tope superior, piso > -100% (precio positivo)
    if jsonb_typeof(v_s->'ajustePct') <> 'number' then
      return jsonb_build_object('ok', false, 'error', 'Segmento '||(v_i+1)||': ajustePct requerido');
    end if;
    v_aj := (v_s->>'ajustePct')::numeric;
    if v_aj = 0 then
      return jsonb_build_object('ok', false, 'error', 'Segmento '||(v_i+1)||': el ajuste no puede ser 0% (sería redundante)');
    end if;
    if v_aj <= -100 then
      return jsonb_build_object('ok', false, 'error', 'Segmento '||(v_i+1)||': el ajuste no puede bajar 100% o mas (el precio quedaria en 0 o negativo)');
    end if;
    -- minIncl default true; maxIncl default false (paridad: s.minIncl !== false ; s.maxIncl === true)
    v_minc := not ((v_s->'minIncl') = 'false'::jsonb);
    v_maxc := ((v_s->'maxIncl') = 'true'::jsonb);
    -- limpiar (round gramos a entero; nombre <=40; ajuste 2 dec)
    v_seg := jsonb_build_object(
      'id',        coalesce(nullif(btrim(coalesce(v_s->>'id','')),''), 'seg-'||(extract(epoch from clock_timestamp())*1000)::bigint::text||'-'||v_i),
      'nombre',    left(coalesce(v_s->>'nombre',''), 40),
      'min',       round(v_min)::int,
      'max',       case when v_max is null then null else round(v_max)::int end,
      'minIncl',   v_minc,
      'maxIncl',   v_maxc,
      'ajustePct', round(v_aj, 2),
      'creadoEn',  coalesce(nullif(btrim(coalesce(v_s->>'creadoEn','')),''), to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
    );
    v_limpios := v_limpios || jsonb_build_array(v_seg);
  end loop;

  -- 2) detectar solapamientos entre cada par (réplica de _segmentosSolapan)
  v_n := jsonb_array_length(v_limpios);
  for v_ia in 0 .. v_n - 2 loop
    for v_ib in v_ia + 1 .. v_n - 1 loop
      v_a := v_limpios -> v_ia;  v_b := v_limpios -> v_ib;
      v_amin := (v_a->>'min')::numeric;  v_bmin := (v_b->>'min')::numeric;
      v_amax := case when (v_a->'max') is null or jsonb_typeof(v_a->'max')='null' then null else (v_a->>'max')::numeric end;
      v_bmax := case when (v_b->'max') is null or jsonb_typeof(v_b->'max')='null' then null else (v_b->>'max')::numeric end;
      v_amaxc := ((v_a->'maxIncl') = 'true'::jsonb);  v_amincl := not ((v_a->'minIncl') = 'false'::jsonb);
      v_bmaxc := ((v_b->'maxIncl') = 'true'::jsonb);  v_bmincl := not ((v_b->'minIncl') = 'false'::jsonb);

      v_solapan := true;
      -- if aMaxEff < b.min return false  (aMaxEff = Infinity si v_amax es null → nunca < b.min)
      if v_amax is not null and v_amax < v_bmin then
        v_solapan := false;
      elsif v_amax is not null and v_amax = v_bmin then
        -- frontera: solapan solo si AMBOS extremos cerrados; si no → false
        if (not v_amaxc) or (not v_bmincl) then v_solapan := false; end if;
      end if;
      if v_solapan then
        -- if bMaxEff < a.min return false
        if v_bmax is not null and v_bmax < v_amin then
          v_solapan := false;
        elsif v_bmax is not null and v_bmax = v_amin then
          if (not v_bmaxc) or (not v_amincl) then v_solapan := false; end if;
        end if;
      end if;

      if v_solapan then
        return jsonb_build_object('ok', false, 'error',
          'Solapamiento entre "'||coalesce(nullif(v_a->>'nombre',''),(v_ia+1)::text)||'" y "'||coalesce(nullif(v_b->>'nombre',''),(v_ib+1)::text)||'"');
      end if;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'segmentos', v_limpios);
end;
$function$
