# #9 — Modelo ÚNICO de ticket (NV / Boleta / Factura / NC) — propuesta + opciones

## Estado actual (diagnóstico)
Hay **dos** generadores de ticket, y por eso "la reimpresión no es igual al original":

| Punto de emisión | Generador | QR | Dónde |
|---|---|---|---|
| **Emisión ORIGINAL** (al cobrar) | builder ESC/POS **local** en ME (offline-first) | sí (qrESCPOS) | `MosExpress/index.html` |
| **REIMPRESIÓN** (ME y MOS) | **Edge `ticket-comprobante`** | sí (QR SUNAT real / correlativo) | `supabase/functions/ticket-comprobante` |

La **Edge ya es el modelo bueno y completo**: header con wordmark + razón social/RUC/dirección, tipo+correlativo grande, cliente, items con cantidad inteligente (granel kg/g), totales con IGV desglosado (gravada/exon/inaf), **QR** (SUNAT real en CPE; correlativo en NV) y **leyenda fiscal + hash**. El builder local es más viejo y difiere en detalles.

## El mockup del modelo único (80mm)
```
            MOSexpress
        INVERSIONES MOS
        R.U.C. 20XXXXXXXXX
     Av. Ejemplo 123 - Ica
     Tel 956XXXXXX  mos@...
================================
   BOLETA DE VENTA            ← grande
   BBB1-000004                ← grande
--------------------------------
Fecha: 28/06/2026 14:30  Cajero: levo
Cliente: JUAN PEREZ PEREZ
RUC      : 20XXXXXXXXX
--------------------------------
DESCRIPCION              IMPORTE
Arroz costeño 750g
  2  x  S/ 3.50          S/ 7.00
Azúcar rubia (granel)
  0.500 kg x S/ 4.00/kg  S/ 2.00
--------------------------------
OP. GRAVADA            S/ 7.63
IGV (18%)              S/ 1.37
TOTAL                  S/ 9.00   ← grande
Forma de pago: EFECTIVO
--------------------------------
        ▛▀▟ QR ▙▀▜            ← CPE: QR SUNAT real
        ▙▄▟    ▙▄▟              NV: correlativo
   Representacion impresa de la
   BOLETA. Autorizado R.I. SUNAT
   Hash: a1b2c3d4...
```
Diferencias por tipo: **NV** → QR=correlativo + pie "no es comprobante de pago electrónico". **Boleta/Factura** → QR SUNAT + "Autorizado R.I. SUNAT" + Hash. **Factura** → además exige razón social + dirección fiscal del cliente. **NC/ND** (nota crédito/débito, a futuro) → mismo molde + referencia al documento que modifica.

## El problema a resolver
Centralizar en UN molde, PERO la emisión original **debe imprimir offline** (el POS es offline-first) y la Edge necesita red. Y son **dos runtimes** distintos (Edge = Deno/TS, ME = navegador/JS). Por eso hay que elegir cómo:

## Opciones

**Opción A — Edge-first + fallback local (online usa la Edge).** Al cobrar, si hay red → imprime por la Edge (idéntico a la reimpresión); si no hay red → builder local. 
- ✅ Online (caso común con wifi) = 1 sola fuente, siempre idéntico. 
- ⚠️ Offline imprime el builder local → hay que mantenerlo a la par. Sigue habiendo 2 generadores.

**Opción B — Builder local reescrito para clonar la Edge (local-first).** Sigue imprimiendo local (rápido, offline), pero se reescribe para producir EXACTO el mismo layout que la Edge. La Edge queda solo para reimpresión.
- ✅ Original rápido + offline + se ve igual. 
- ⚠️ Dos implementaciones del MISMO formato (TS y JS) → mantener sincronizadas a mano.

**Opción C — Spec compartido (una verdad).** El formato se describe UNA vez (un "layout spec" en datos) que tanto la Edge como ME interpretan para generar el ESC/POS. 
- ✅ Verdadero modelo único: cambias el formato en un lugar. 
- ⚠️ Más trabajo inicial (definir el spec + dos intérpretes), pero paga a largo plazo.

**Opción D (recomendada) — Edge-first online + fallback local CLONADO (A+B).** Online → Edge (canónico). Offline → builder local **alineado al layout de la Edge**. Lo mejor de ambos: online siempre idéntico y centralizado; offline funciona y se ve igual.
- ✅ Robusto, offline-safe, original==reimpresión en el 99% de casos (online). 
- ⚠️ El fallback local hay que clonarlo una vez (pero como la Edge ya está hecha, es portar su layout).

## Recomendación
**Opción D.** Es la única que respeta el offline-first del POS (dinero) Y centraliza. Plan:
1. Wire `procesarVenta` → imprimir por la Edge `ticket-comprobante` cuando hay red (reusa el mismo RPC/Edge de la reimpresión, mismo `idVenta`).
2. El builder local de ME se realinea al layout de la Edge (solo como fallback offline).
3. QR: ya está en la Edge; el fallback local debe incluir el QR id-ticket (NV) y, si el CPE ya tiene `nfQr/nfHash` local, el QR SUNAT.
4. NC/ND: el molde queda listo para sumarlas cuando se emitan.

**Pendiente de tu decisión:** ¿Opción D (recomendada), o prefieres A/B/C? Una vez elijas, lo implemento con revisión 500x (es ruta de dinero/impresión).
