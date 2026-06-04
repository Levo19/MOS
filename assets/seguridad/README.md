# Sistema Seguridad — `/assets/seguridad/`

UI centralizada de dispositivos + horarios para las 3 apps.

## API pública

```javascript
window.SeguridadSystem = {
  iniciar({ apiPost, usuario, rol, idPersonal, app, unwrapData, endpointPrefix }),

  // ADMIN (MOS)
  arrancarBadgeAlertas(),       // badge flotante alertas
  abrirModalAlertas(),          // modal 3 tabs (pend/susp/todos)
  abrirModalDesbloqueoTemporal(deviceId, nombre),
  abrirModalConfigHorarios(),

  // OPERADOR (WH+ME)
  abrirModalSolicitarAcceso({ enInSitu, enRemoto }),
  abrirModalFueraHorario(motivo, apertura, cierre),
  arrancarWidgetMiHorario(),    // widget dashboard WH

  // INTERNOS expuestos para handlers HTML
  sonidos: {...}
};
```

## Carga

```html
<!-- MOS -->
<script src="./assets/seguridad/seguridad-modal.js?v=X"></script>

<!-- WH y ME -->
<script src="https://levo19.github.io/MOS/assets/seguridad/seguridad-modal.js?v=X"></script>
```

## Setup en producción

```javascript
// Editor GAS MOS (1 vez):
setupTodoSeguridad();                     // sheet alertas + cols dispositivos
instalarTriggerPurgarDispositivos();      // diario suspende inactivos 7d
instalarTriggerRevertirDesbloqueos();     // cada hora revierte vencidos
```
