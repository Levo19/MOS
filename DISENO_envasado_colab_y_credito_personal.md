# DISEÑO · Envasado colaborativo + Línea de crédito del personal

> Estado: **DIBUJO — pendiente OK del dueño. NO implementado.**
> Fecha: 2026-07-11 · Datos verificados en producción (Jorgenis OP001 como caso real).
> Directrices: cero-GAS, revisión adversarial antes de declarar listo, money-safe.

---

## PARTE 1 · Envasado colaborativo (🤝 "Team")

### Cómo funciona hoy (verificado)
- Registro: `wh.registrar_envasado` (SQL 60) → guías SALIDA/INGRESO_ENVASADO + stock + kardex + lotes. La fila queda en `wh.envasados` con **`usuario` = un solo nombre**.
- Pago: recompute (SQL 289, disparado por triggers 291) para rol ENVASADOR/ALMACENERO:
  `pago_envasado = Σ unidades_producidas (no ANULADO, match por _norm_nom(usuario)) × tarifa_envasado (config, 0.10)` → `liquidaciones_dia.pago_envasado` + `productos_envasados`.
- Real de OP001: 2026-07-11 → 160 u = S/16.00.

### Cambio propuesto
**El registro es EXACTAMENTE el mismo** (guías, stock, adhesivos, lotes: cero cambios). Solo se agrega la dimensión "con quién":

1. **`wh.envasados` + 1 columna**: `colaborador text default ''` (nombre completo del compañero, mismo formato que `usuario`; `''` = registro normal). El picker del front lo llena desde el personal WH activo (`mos.personal` tipo OPERADOR) — **nunca texto libre** (el match de pago es por nombre normalizado).
2. **Regla de dinero** (el negocio paga LO MISMO, solo se reparte):
   - Registro normal: creador cobra `unidades × tarifa`.
   - Registro 🤝: cada uno cobra la mitad. Redondeo money-safe: `colaborador = round(unid × tarifa / 2, 2)` y `creador = round(unid × tarifa, 2) − colaborador` (la suma SIEMPRE cuadra con el total; el creador absorbe el céntimo si lo hay).
3. **Recompute 289 v2** — para cada persona del día:
   ```
   propios      = Σ unid (usuario=yo, colaborador='')
   colab_creador= Σ unid (usuario=yo, colaborador≠'')
   colab_invit  = Σ unid (colaborador=yo)
   pago_envasado        = propios×tarifa + mitad(colab_creador) + mitad(colab_invit)   ← TOTAL (fórmula total_dia intacta)
   productos_envasados  = propios                                                      ← igual que hoy (KPI propio)
   envasados_colab      = colab_creador + colab_invit                                  ← columna NUEVA (unidades)
   pago_envasado_colab  = mitad(colab_creador) + mitad(colab_invit)                    ← columna NUEVA (detalle)
   ```
   `liquidaciones_dia` + 2 columnas informativas (`envasados_colab`, `pago_envasado_colab`). `pago_envasado` sigue siendo el total → `total_dia`, pagos, snapshots y TODO el downstream quedan intactos.
4. **Trigger de recompute**: un registro 🤝 debe recomputar la fila del día de **AMBOS** (hoy el trigger recomputa por `usuario`; se extiende a `colaborador`). Igual en corrección/anulación (SQL 67).
5. **UI WH (modal registrar envasado)**: check `🤝 Colaborativo` → aparecen chips del personal WH activo (menos tú) → eliges 1. La card del historial muestra `🤝 con Luis` y el ticket/detalle divide el monto.
6. **UI MOS (Personal del día / auditoría)**: la fila del operador muestra `envasado propio 160u · 🤝 colab 80u`, y el modal de detalle lista los registros con la marca.
7. **Ticket de liquidación (Edge `imprimir`)**: 
   ```
   Por envasado (propios)      160 u   S/ 16.00
   Por envasado 🤝 colab (50%)  80 u   S/  4.00
   ```

### Decisiones tomadas (cambiables)
- Solo **1 colaborador** por registro (mitad y mitad). Si un día quieren 3 personas, se hacen 2 registros — mantiene el modelo simple.
- El colaborador NO firma/aprueba: el creador lo elige y queda auditado (usuario, colaborador, fecha en la fila). Si hay abuso, se ve en el detalle diario y el admin corrige (SQL 67 corregir/anular ya existe).
- `productos_envasados` conserva su significado actual (propios) para no romper KPIs históricos; lo colaborativo va en columna aparte.

---

## PARTE 2 · Línea de crédito del personal (notas de crédito por documento)

### Lo que existe hoy (verificado en prod)
- `mos.personal`: **NO tiene documento** (columnas: id, nombre, apellido, tipo, rol, pin, monto_base, …).
- `me.ventas`: tiene `cliente_doc`, `forma_pago` — hay ventas `CREDITO` reales.
- Flujo de cobro existente: `me.creditos_cobro_asignado` + `cobrar_venta` (al cobrar, cambia `forma_pago` CREDITO→EFECTIVO/VIRTUAL con `historial_cambios`). **El descuento por planilla debe convivir con esto sin doble-cobro.**
- **Caso real Jorgenis (OP001)**: sus tickets a crédito salen con el doc escrito de 3 formas: `853904`, `008539040`, `087539040` (typos + tema DNI con cero inicial). Deuda viva ≈ **S/ 58.60 en 11 tickets** (jun-16 → jul-09). Esto obliga a diseñar el matching Y la higiene de captura.

### Cambio propuesto

**A. Identidad**
- `mos.personal` + columna `documento text` (DNI 8 díg; normalizado solo-dígitos al guardar). Editor de Personal en MOS con el campo.
- **Higiene de captura en ME** (la clave para que esto funcione): al elegir forma de pago CRÉDITO, además del flujo actual, un atajo `👷 Empleado` que lista el personal (con documento registrado) y **estampa el doc registrado** en el ticket — se acabó el doc tipeado a mano. Los tickets viejos/sucios: el master los corrige una vez con el flujo existente `editar_cliente`.

**B. Matching (lectura diaria)**
- `creditos_pendientes(personal)` = ventas con `forma_pago='CREDITO'` y `_norm_doc(cliente_doc) = _norm_doc(personal.documento)` (solo dígitos; tolerancia cero-inicial estilo `architecture_me_dni_puede_empezar_con_cero`). Los que no matcheen por typo → los corrige el master (punto A).

**C. Dónde se ve (diario)**
- Personal del día (MOS): la fila del empleado suma un chip `🧾 crédito S/ 58.60 (11)`. El modal de detalle lista ticket × ticket (fecha, correlativo, monto).
- El acumulado NO altera `total_dia` diario — es informativo hasta la liquidación (el jornal del día no se toca).

**D. Dónde se descuenta (al liquidar/pagar)**
- En el modal de pago de liquidación (flujo actual de pagos jornal): sección **"Notas de crédito"** con el detalle y check por ticket (default: todos marcados). 
  ```
  Jornal semana:            S/ 480.00
  − Nota crédito V-…9540    S/  10.00
  − Nota crédito V-…6741    S/  10.00
  Neto a pagar:             S/ 460.00
  ```
- **Regla de tope**: el descuento nunca deja el pago en negativo; si la deuda > jornal, se descuenta hasta 0 y el resto queda pendiente para la siguiente liquidación.
- **Settlement money-safe (el punto crítico)**: al confirmar el pago:
  1. Cada ticket descontado cambia `forma_pago` → **`PLANILLA`** (valor nuevo, análogo al cobrar_venta actual) + entrada en `historial_cambios` (`accion:'descuento_planilla'`, `id_pago` de la liquidación).
  2. Fila puente en tabla nueva `mos.creditos_planilla` (id_venta, id_personal, id_pago, monto, fecha) = auditoría y fuente de "ya descontado".
  3. Así el ticket **desaparece de créditos por cobrar** (no se puede cobrar doble por el flujo de cobros de caja) y **no entra a ninguna caja** (no es efectivo que ingresó — se compensó contra jornal). 
  - ⚠️ Punto de validación pre-código: barrer los consumidores de `forma_pago` (reportes/финanzas/`architecture_mos_formapago` habla de 5 valores válidos) para que `PLANILLA` sea reconocido como "cobrado sin caja".
- **Ticket impreso de liquidación** (Edge `imprimir`): sección DESCUENTOS con el detalle ticket a ticket + neto — el operador entiende exactamente qué le descontaron.

### Dibujo del ticket de liquidación final (une las 2 partes)
```
      LIQUIDACIÓN · JORGENIS GONZALEZ
      Semana 06/07 — 12/07
  ──────────────────────────────────────
  Base (6 días × S/80)          S/ 480.00
  Por envasado (propios) 554u   S/  55.40
  Por envasado 🤝 colab  160u   S/   8.00
  Bonificación                  S/   0.00
  Sanción                      −S/   0.00
  ──────────────────────────────────────
  Subtotal jornal               S/ 543.40
  DESCUENTOS — Notas de crédito
   V-…5480  09/07              −S/  12.50
   V-…9943  07/07              −S/   1.00
   V-…8739  07/07              −S/   3.70
   … (8 más)                   −S/  41.40
  ──────────────────────────────────────
  NETO A PAGAR                  S/ 484.80
```

### Orden de implementación sugerido (cuando des OK)
1. P1 backend (columna + recompute + triggers ambos lados) → INERTE, verificable con smoke tx-rollback.
2. P1 frontend WH (check + picker) + MOS detalle + ticket.
3. P2 columna documento + editor MOS + RPC créditos_pendientes + chip/detalle diario (solo LECTURA — cero riesgo).
4. P2 descuento en liquidación + PLANILLA + tabla puente (money — revisión adversarial completa).
5. Limpieza de docs sucios de Jorgenis/Oswalwid (corrección de tickets con editar_cliente) + atajo 👷 Empleado en ME.

### DECISIONES CONFIRMADAS POR EL DUEÑO (2026-07-11)
1. Nombre del tipo: **"🤝 Colaborativo"**.
2. El colaborador **NO confirma** — basta que el creador lo elija (queda auditado).
3. Si la deuda supera el jornal: **la liquidación SÍ puede quedar en NEGATIVO** (se muestra neto negativo; no hay tope a 0 ni arrastre). El ticket puede imprimir `NETO A PAGAR: −S/ X.XX`.
4. Solo cuentan tickets `forma_pago='CREDITO'` **con el documento registrado del personal**. El documento es un **ID de TEXTO — match EXACTO, los ceros a la izquierda NUNCA se descartan ni normalizan** (se elimina del diseño toda idea de padStart/normalización numérica; a lo sumo `btrim`). Documento de Jorgenis = **`008539040`** (carné de extranjería, 9 dígitos). Por ahora solo se registra el suyo.

### Hallazgos de datos (2026-07-11, prod)
**Tickets CREDITO por los 3 docs (histórico completo, todos siguen en CREDITO):**
- `008539040` (doc CORRECTO → contarán): 2 tickets = **S/ 4.70** (07/07 NVa2-002106 S/3.70 · 07/07 NVa2-002107 S/1.00).
- `087539040` (typo, nombre JORGENIS GONZÁLEZ): 1 ticket 09/07 NVa2-002112 = **S/ 12.50** — pendiente confirmación del dueño → corregir doc con `editar_cliente`.
- `853904` (doc incompleto, nombre JORGENIS): **25 tickets del 15/05 al 26/06 = S/ 163.90** — pendiente confirmación → corrección en lote con `editar_cliente`.
- Total potencial si todo es de él: **S/ 181.10**.

**Clientes frecuentes:** Jorgenis **NO existe** en `me.clientes_frecuentes` (0 match por nombre/docs; 25 clientes en la tabla, NINGUNO con doc de 9 dígitos). El buscador no oculta extranjeros — busca sobre la tabla y él no está. ¿Por qué nunca se guardó? En el path Supabase actual **la venta NO persiste al cliente tipeado**; solo escriben a la tabla: (a) el Edge `consultar-documento` cuando RENIEC/SUNAT devuelven hit (DNI 8 / RUC 11 — un CE de 9 dígitos jamás hace hit) y (b) la RPC `editar_cliente` (upsert). El flujo "Cliente CE" del cajero solo llena el ticket, no la tabla. → Fixes que suma este diseño: al registrar el documento en `mos.personal`, **upsert también a `me.clientes_frecuentes`** (tipo CE); el atajo `👷 Empleado` estampa doc+nombre limpios; y corregir los 26 tickets viejos con `editar_cliente` de paso lo deja registrado como frecuente (ese upsert ya existe).

### ✅ Corrección EJECUTADA (2026-07-11, autorizada por el dueño)
Los 26 tickets (853904 + 087539040) se corrigieron a `008539040` vía `me.editar_cliente`
(historial auditado, motivo registrado). Verificado: **28 tickets CREDITO con doc
008539040 = S/ 181.10**, cero residuales. Jorgenis quedó upserted en
`me.clientes_frecuentes` — con `tipo_doc='0'` (el gap del tipo, ver sección C).

---

## PARTE 2-C · Clientes extranjeros (CE/Pasaporte) — tipo explícito + gate de factura

### Norma SUNAT (catálogo 06, verificada 2026-07-11)
| Código | Documento | Longitud |
|---|---|---|
| 1 | DNI | **8 numérico FIJO** |
| 4 | Carné de extranjería | **hasta 12 ALFANUMÉRICO variable** |
| 6 | RUC | **11 numérico fijo** (empieza 10/15/16/17/20) |
| 7 | Pasaporte | **hasta 12 ALFANUMÉRICO variable** |

⚠️ **CONFIRMADO el riesgo que señaló el dueño**: un CE o pasaporte SÍ puede tener 11
caracteres → colisiona con la longitud del RUC. Inferir tipo por longitud (lo que hace
hoy `editar_cliente`: 8→DNI, 11→RUC, resto→0) es INSUFICIENTE y podría habilitar una
FACTURA a un doc que no es RUC.

### ✅ PARTE 2-C IMPLEMENTADA Y DESPLEGADA (2026-07-11 · SQL 417 + ME v2.8.192)
Candados FACTURA (bypass CE cerrado, RUC real con prefijo en emitir Y convertir
NV→CPE, reuso de frecuente CE/Pasaporte hereda tipo y bloquea factura), mini-form
Extranjero guarda en frecuentes (chips CE 4 / Pasaporte 7), búsqueda en vivo
server+local, Jorgenis = tipo 4 buscable al toque. Smoke 8/8.
⚠️ Follow-up: cuando se active CPE (fac.emitir_cpe, hoy INERTE), replicar la
validación de prefijo RUC server-side en su guard de FACTURA (hoy el server
valida 11 dígitos; el frontend ya bloquea antes).

### Reglas de diseño
1. **El tipo se guarda EXPLÍCITO, nunca se infiere por longitud.** `me.clientes_frecuentes.tipo_doc`
   pasa a usar el catálogo SUNAT: '1' DNI · '4' CE · '6' RUC · '7' PASAPORTE · '0' otros.
   (Hoy la columna tiene basura mixta: 'NOTA_DE_VENTA', 'BOLETA', '1', '0' → migración de limpieza:
   8 díg numérico→1, 11 díg numérico con prefijo RUC válido→6, resto→0 y se corrigen a mano los CE conocidos, empezando por Jorgenis→'4'.)
2. **Gate de FACTURA = doble candado**: tipo_doc='6' **Y** validación de RUC real
   (11 dígitos numéricos + prefijo 10/15/16/17/20). Un CE/pasaporte de 11 caracteres
   NUNCA habilita factura aunque la longitud coincida. Boleta ≥ S/700 exige identificar:
   acepta DNI/CE/pasaporte (SUNAT lo permite); factura SOLO RUC.
3. **El mini-form "Extranjero" (CE/Pasaporte + nombre) PERSISTE a `me.clientes_frecuentes`**
   con su tipo ('4' o '7' según lo que elija el cajero) — hoy solo llena el ticket y muere.
   La próxima venta filtra por nombre o documento al instante.
4. `editar_cliente` acepta `tipoDoc` explícito como parámetro (manda sobre la inferencia);
   la inferencia por longitud queda solo de fallback legacy con la validación de prefijo RUC.
5. El atajo `👷 Empleado` estampa doc + nombre + tipo registrados desde `mos.personal`.
