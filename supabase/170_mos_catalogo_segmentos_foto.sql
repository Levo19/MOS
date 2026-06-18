-- 170_mos_catalogo_segmentos_foto.sql — [CATÁLOGO DELETE-SAFE] Cierra las 2 piezas que mantenían MOS_CATALOGO_DIRECTO=0:
--   (1) SEGMENTOS DE PRECIO (graneles KGM): mos.actualizar_segmentos_precio(p) porta _validarSegmentosPrecio
--       (sin solapamientos, KGM-only, canónico-only) y escribe mos.productos.segmentos_precio (jsonb, ya existe).
--   (2) FOTO de producto a Supabase Storage: bucket 'producto-fotos' (público, RLS app='MOS') + mos.set_foto_producto(p)
--       que persiste foto_url en TODAS las filas del mismo sku_base (paridad subirFotoProducto de GAS).
--
-- ⚠️ NACE INERTE bajo el MISMO flag mos.config.MOS_CATALOGO_DIRECTO (sembrado en 78, default '0') + mos._claim_ok().
--    Sin cablear js/api.js (otra parte de esta tanda), nadie las llama. Con el flag OFF las RPCs devuelven *_OFF
--    → el front cae a GAS = idéntico a hoy.
--
-- ── POR QUÉ CIERRA EL CUTOVER ────────────────────────────────────────────────────────────────────────────
--   GAS no escribía foto_url/segmentos_precio en mos.* salvo por dual-write desde la HOJA: la foto vivía en Drive
--   (atada al SA) y los segmentos NO tenían RPC. Acá ambas piezas escriben DIRECTO a mos.productos → el catálogo
--   ya no necesita la HOJA para ninguna escritura → es delete-safe del Sheet (con el flag ON + sync de
--   productos/equivalencias apagado, que se hace en una pieza aparte sobre mos.config.MOS_SYNC_OFF_TABLAS).
--
-- ── COLUMNAS ─────────────────────────────────────────────────────────────────────────────────────────────
--   mos.productos.segmentos_precio jsonb  — YA existe (verificado). El sync la mapea de la cabecera 'segmentos_precio'.
--   mos.productos.foto_url text           — YA existe (verificado). El sync la mapea de la cabecera 'fotoUrl'.

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- (A) BUCKET DE STORAGE 'producto-fotos' — espejo del patrón wh-fotos (61), pero gateado a app='MOS'.
--   Público (lectura por URL, como estaban en Drive con ANYONE_WITH_LINK) — fotos de catálogo, no datos personales.
--   Subir/actualizar/borrar: solo apps con claim MOS (auth.jwt()->>'app'='MOS'). Límite 15 MB/foto (alta resolución).
--   Organización por path: productos/<skuBase>/<archivo>.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('producto-fotos', 'producto-fotos', true, 15728640, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists producto_fotos_insert on storage.objects;
drop policy if exists producto_fotos_update on storage.objects;
drop policy if exists producto_fotos_delete on storage.objects;

create policy producto_fotos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'producto-fotos' and (auth.jwt()->>'app') = 'MOS');
create policy producto_fotos_update on storage.objects for update to authenticated
  using (bucket_id = 'producto-fotos' and (auth.jwt()->>'app') = 'MOS')
  with check (bucket_id = 'producto-fotos' and (auth.jwt()->>'app') = 'MOS');
create policy producto_fotos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'producto-fotos' and (auth.jwt()->>'app') = 'MOS');

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- (B) mos._validar_segmentos_precio(segs jsonb) → jsonb  — porta _validarSegmentosPrecio + _segmentosSolapan (GAS).
--   Devuelve {ok:true, segmentos:[...]} (limpios, ordenados como llegaron) o {ok:false, error:'...'} (mismo texto que GAS).
--   Reglas (paridad EXACTA con gas/Productos.gs):
--     · array → [] vacío es válido (limpia los segmentos).
--     · min: número >= 0.   · max: null (infinito) o número > min.   · ajustePct: número, ≠0, en [-50, 50].
--     · minIncl default true; maxIncl default false.  · no solapan entre sí (frontera cerrada/cerrada = solapa).
--   Limpieza: min/max redondeados a entero (gramos); nombre recortado a 40; ajustePct a 2 decimales; id/creadoEn estables.
--   INTERNA (sin flag/claim): la usa actualizar_segmentos_precio (definer). EXECUTE solo service_role.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos._validar_segmentos_precio(segs jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $fn$
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
    -- ajustePct: number, ≠0, en [-50, 50]
    if jsonb_typeof(v_s->'ajustePct') <> 'number' then
      return jsonb_build_object('ok', false, 'error', 'Segmento '||(v_i+1)||': ajustePct requerido');
    end if;
    v_aj := (v_s->>'ajustePct')::numeric;
    if v_aj = 0 then
      return jsonb_build_object('ok', false, 'error', 'Segmento '||(v_i+1)||': el ajuste no puede ser 0% (sería redundante)');
    end if;
    if v_aj < -50 or v_aj > 50 then
      return jsonb_build_object('ok', false, 'error', 'Segmento '||(v_i+1)||': ajustePct debe estar entre -50 y +50');
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
$fn$;
revoke all on function mos._validar_segmentos_precio(jsonb) from public;
grant execute on function mos._validar_segmentos_precio(jsonb) to service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.actualizar_segmentos_precio(p jsonb) — espeja actualizarSegmentosPrecio (gas/Productos.gs).
--   p = { idProducto, segmentos:[...], usuario? }. Valida (KGM + canónico + sin solapamientos) y persiste
--   mos.productos.segmentos_precio (jsonb). Idempotente (UPDATE atómico al mismo valor = no-op). Append al
--   historial_cambios (paridad GAS: entrada 'actualizar_segmentos'). Devuelve {ok,segmentos,total} igual que GAS.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.actualizar_segmentos_precio(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_segs  jsonb := coalesce(p->'segmentos', '[]'::jsonb);
  v_val   jsonb;
  v_limpios jsonb;
  v_row   record;
  v_um    text;
  v_fc    numeric;
  v_hist  jsonb;
  v_entry jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idProducto requerido'); end if;

  -- validar segmentos (réplica _validarSegmentosPrecio) — si falla, mismo {ok:false,error} que GAS
  v_val := mos._validar_segmentos_precio(v_segs);
  if not (v_val->>'ok')::boolean then return v_val; end if;
  v_limpios := v_val->'segmentos';

  select * into v_row from mos.productos where id_producto = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','Producto no encontrado: '||v_id); end if;

  -- granel KGM-only (paridad GAS)
  v_um := upper(coalesce(v_row.unidad_medida,''));
  if v_um <> 'KGM' then
    return jsonb_build_object('ok',false,'error','Solo productos KGM (granel) admiten segmentos · este es '||coalesce(nullif(v_um,''),'sin unidad'));
  end if;
  -- canónico-only (factor=1) — los segmentos viven en el canónico (paridad GAS: parseFloat(fc||1) !== 1)
  v_fc := coalesce(v_row.factor_conversion, 1);
  if v_fc <> 1 then
    return jsonb_build_object('ok',false,'error','Los segmentos se configuran en el canónico (factor=1), no en presentaciones');
  end if;

  -- persistir + append al historial (réplica del bloque de auditoría de GAS)
  v_entry := jsonb_build_object(
    'ts',      to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'usuario', coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'admin'),
    'source',  'MOS_SEGMENTOS_PRECIO',
    'accion',  'actualizar_segmentos',
    'cambios', jsonb_build_array(jsonb_build_object('campo','segmentos_precio','cantidad', jsonb_array_length(v_limpios)))
  );
  v_hist := case when jsonb_typeof(v_row.historial_cambios) = 'array' then v_row.historial_cambios else '[]'::jsonb end;
  v_hist := v_hist || jsonb_build_array(v_entry);
  -- limitar a últimas 50 (paridad GAS slice(-50))
  if jsonb_array_length(v_hist) > 50 then
    v_hist := (select jsonb_agg(e) from (select e from jsonb_array_elements(v_hist) with ordinality t(e,o) order by o offset (jsonb_array_length(v_hist) - 50)) s);
  end if;

  update mos.productos set
    segmentos_precio  = v_limpios,
    historial_cambios = v_hist,
    updated_at        = now()
  where id_producto = v_id;

  return jsonb_build_object('ok', true, 'segmentos', v_limpios, 'total', jsonb_array_length(v_limpios));
end;
$fn$;
revoke all on function mos.actualizar_segmentos_precio(jsonb) from public;
grant execute on function mos.actualizar_segmentos_precio(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- mos.set_foto_producto(p jsonb) — persiste foto_url tras subir el binario a Storage (browser→bucket producto-fotos).
--   p = { skuBase, fotoUrl }. Espeja subirFotoProducto (gas): actualiza foto_url en TODAS las filas del mismo
--   sku_base (canónico + presentaciones + equivalentes comparten foto). Idempotente (setea la URL; reintento = misma).
--   ⚠️ NO sube el archivo (eso lo hace el front contra Storage con el JWT MOS) — solo persiste la URL pública.
--   Devuelve {ok, data:{skuBase, fotoUrl, actualizados}} (paridad de shape con GAS: el front lee r.fotoUrl).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.set_foto_producto(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_url  text := nullif(btrim(coalesce(p->>'fotoUrl','')), '');
  v_n    int;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;
  if v_url is null then return jsonb_build_object('ok',false,'error','fotoUrl requerido'); end if;

  update mos.productos set foto_url = v_url, updated_at = now() where sku_base = v_sku;
  get diagnostics v_n = row_count;
  -- v_n=0 NO es error: puede que la sombra aún no tenga la fila (sync pendiente); el front ya tiene la URL optimista.
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('skuBase', v_sku, 'fotoUrl', v_url, 'actualizados', coalesce(v_n,0)));
end;
$fn$;
revoke all on function mos.set_foto_producto(jsonb) from public;
grant execute on function mos.set_foto_producto(jsonb) to service_role, authenticated;
