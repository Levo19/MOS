# B5 — Edge Functions: Fotos (Drive) + IA (Claude). Diseño + conexión.

> Decisiones del usuario (2026-06-13): (1) TODAS las fotos en Drive (no Storage); pidió mejor organización por
> carpetas/numeración (son muchas: guías, productos, preingresos, mermas). (2) IA = el Claude API que ya usa GAS.

## 1. Cómo se conecta la Edge a Google Drive (SERVICE ACCOUNT)
La Edge (Deno, server-side) NO puede usar el DriveApp de GAS. Se conecta a Drive API v3 con un **service account**:
1. **Google Cloud Console** (mismo proyecto donde está habilitada Drive API): crear un *Service Account* → generar **key JSON**.
2. **Compartir** la carpeta raíz de fotos de WH (`WH_FOTOS_ROOT_FOLDER_ID`) con el email del SA (`xxx@xxx.iam.gserviceaccount.com`) como **Editor**. (Y las legacy: MERMAS/FOTOS_PN/FOTOS_GUIA folders, para que el proxy las lea.)
3. **Secret** en Supabase: `supabase secrets set GOOGLE_SA_JSON='<contenido del json>' --project-ref rzbzdeipbtqkzjqdchqk`.
4. La Edge: firma un JWT RS256 con la private key del SA → lo intercambia en `oauth2.googleapis.com/token` por un **access_token** (scope `https://www.googleapis.com/auth/drive`) → llama Drive API v3 (upload multipart / get media). El token se cachea ~50 min.

## 2. Organización propuesta (CONSOLIDAR sobre el patrón de Fotos.gs)
Hoy: bien en `Fotos.gs` (root/yyyyMM/entidad/idEntidad) PERO legacy disperso (mermas/PN/guías en carpetas sueltas).
**Propuesta — una sola estructura, particionada por mes + entidad + id:**
```
warehouseMos_Fotos/                         (raíz = WH_FOTOS_ROOT_FOLDER_ID, ya existe)
  2026-06/                                  (año-mes → ninguna carpeta crece sin límite)
    guias/<idGuia>/        foto_1.jpg, foto_2.jpg, ...   (numeradas)
    preingresos/<idPreingreso>/ foto_1.jpg ...
    mermas/<idMerma>/      foto_1.jpg
  productos/<codigoBarra>/ foto.jpg          (productos NO por mes: 1 carpeta fija por código)
```
- **Numeración** `foto_<n>.jpg` dentro de cada id (varias fotos por entidad).
- **Migración**: las fotos VIEJAS se quedan donde están (sus URLs/fileId siguen sirviendo por el proxy); la estructura
  nueva aplica a fotos NUEVAS. No hay que mover lo existente (riesgoso). Opcional: un script de reorganización futuro.
- Beneficio: encontrar todas las fotos de una guía = 1 carpeta; backups/borrado por mes; nada gigante.

## 3. Edge Functions a crear
- **`fotos`** (una Edge, acción por body): 
  - `subir` → {tipo:'guia'|'preingreso'|'merma'|'producto', id, base64, mime} → crea/reusa carpeta `yyyyMM/tipo/id`
    (o `productos/<cod>`), nombre `foto_<n>`, sube, marca ANYONE_WITH_LINK, devuelve {fileId, url}.
  - `ver`/GET `?fileId=` → stream de la imagen (proxy; la PWA nunca toca Drive directo).
  - `eliminar` → {fileId} → borra (reemplaza eliminarFotoDrive de GAS).
  - Auth: claim app ∈ {warehouseMos} (como la Edge `imprimir`).
- **`ia`** (OCR boleta / parser listas): reusa `ANTHROPIC_API_KEY` (secret), modelo `claude-haiku-4-5-20251001`,
  endpoint `api.anthropic.com/v1/messages`, header `x-api-key`+`anthropic-version: 2023-06-01`. Replica los prompts de IA.gs.
  Secret: `supabase secrets set ANTHROPIC_API_KEY=<la misma del GAS>`.

## 4. Wiring en el front (api.js)
- `subirFotoMerma/subirFotoGuia/subirFotoPreingreso/actualizarFotosPreingreso` → POST a Edge `fotos` acción subir.
- Mostrar fotos → `GET Edge fotos?fileId=` (o la url pública si es ANYONE_WITH_LINK).
- `eliminarFotoDrive` → Edge `fotos` acción eliminar. IA (analizarListaSombra, OCR preingreso) → Edge `ia`.
- Todo con flag + fallback a GAS (inerte hasta activar).

## Secrets que pone el usuario (no entran al repo)
- `GOOGLE_SA_JSON` (service account con acceso a las carpetas de Drive)
- `ANTHROPIC_API_KEY` (la misma de GAS)
Deploy: `supabase functions deploy fotos` + `... ia` (con token, como ME).
