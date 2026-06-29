# Punto de retoma — Auditoría/pagos: vetar unificado + bonif/sanción separadas + impresión

## Contexto
Análisis de 5 issues que reportó el dueño sobre personal del día / liquidación / auditoría.
Directrices: **100% Supabase (cero-GAS)** + **revisión rigurosa antes de tocar dinero**.

## Decisiones del dueño (confirmadas)
1. Modal de auditoría: **bonificación Y sanción SEPARADAS** (coexisten, cada una con su comentario).
2. **VETAR unificado en AMBAS vistas** (personal del día + liquidación), mismo estado VETADA + enmallado + desvetar. La sanción queda como descuento parcial, aparte.
3. Comisión del jornal = por DÍA (zona supera meta → 5% excedente proporcional). El ticket de caja la marca PROVISIONAL (ya hecho, GAS @436 — migrar a Edge pendiente).

## Diagnóstico (causa raíz, ya trazada)
- **"Texto raro" en el motivo**: (a) el front armaba un tag `📊 S/x → S/y (+z)` y lo concatenaba al motivo (`app.js` ~37983-38001) — **YA ELIMINADO (v2.43.372)**; (b) GAS `Evaluaciones.gs:143-173` FUSIONA (join ' · ') todos los motivos del día → aún puede duplicar comentarios.
- **Campos mezclados**: el modal tiene UN solo "ajuste" con toggle sanción XOR bonificación (`app.js:37974`, `auditAjusteTipo`). No permite ambas.
- **Día equivocado (domingo→lunes)**: el guardado usa `fechaAudit = auditR.fecha || _evalState.fecha` (`app.js:38016`). Si el panel estaba en lunes, el bono se aplica a lunes. Falta UI clara del día + selector.
- **Vetar**: solo existe en liquidación (`_liqDiaRow` → 💸 `_liqConfirmarVetar` → `_liqVetarDia` → estado VETADA; reversible `_liqDesvetarDia`). Personal del día NO tiene vetar — lo que "baja el gasto" ahí es la SANCIÓN. RPC `mos.vetar_liquidacion_dia`/`desvetar_liquidacion_dia` ya en Supabase (flag MOS_LIQDIA_DIRECTO=1).
- **Tres conceptos distintos**: comisión por ventas (`bono_meta`, auto) / bonificación manual (+, con motivo) / sanción manual (−, con motivo). El total ya los separa: `total_dia = monto_base + pago_envasado + bono_meta + bonificacion − sancion`.
- **Liquidación lee/escribe Supabase**: flags `MOS_LIQDIA_DIRECTO/MOS_EVAL_DIRECTO/MOS_PAGOS_DIRECTO/...LECTURA` todos en 1. Lentitud solo si el fallback de frescura cae a GAS → verificar por pestaña.

## HECHO
- ✅ v2.43.372: eliminado el tag `📊` del motivo (`app.js` guardarAuditoria). Motivo = comentario limpio.

## PENDIENTE (siguiente tanda, en orden)
1. **Modal 2 campos** (`modalAuditar` HTML + `app.js` guardarAuditoria + `_renderAuditLiquidacion`):
   - Reemplazar el ajuste único (toggle) por DOS bloques: Bonificación (monto + motivo) y Sanción (monto + motivo), independientes.
   - Guardar ambos vía `mos.set_bonificacion_sancion` (soloTipo=null setea ambos, preservando lo no enviado). Motivos limpios.
2. **Quitar la FUSIÓN de motivos** (cero-GAS): que el motivo = el comentario del último ajuste, no la concatenación. Idealmente mover el set a Supabase directo (set_bonificacion_sancion ya existe) y dejar de pasar por la fusión GAS de `Evaluaciones.gs`.
3. **Vetar unificado**: agregar botón vetar/desvetar (estado VETADA) + **efecto enmallado** (CSS hatched) en personal del día, reusando las RPC. Misma UX en ambas vistas.
4. **Selector de fecha** en el ajuste (evitar domingo→lunes): mostrar el día en grande + permitir elegirlo.
5. **Ticket impreso de liquidación de pago**: formatear bonificación / sanción / comisión cada una en su línea con su comentario (multilínea). Revisar el builder (Liquidaciones.gs `imprimirLiquidacion*` / o Edge). Migrar a Edge (cero-GAS).
6. Verificar cada pestaña de liquidación (pendientes/pagadas/vetadas/pagos) resuelve lectura directa Supabase (no fallback GAS).
