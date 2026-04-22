# MOS Admin

Panel de administración central del ecosistema **InversionMos**.  
Conecta y orquesta las tres apps: **MOS** (maestro) · **warehouseMos** (almacén) · **MosExpress** (punto de venta).

---

## Stack

| Capa | Tecnología |
|---|---|
| Frontend | HTML + Tailwind CSS CDN + Chart.js |
| Backend | Google Apps Script (GAS) — Web App |
| Base de datos | Google Sheets |
| Hosting | GitHub Pages (`main` branch) |

Sin Node.js, sin build step. Todo estático.

---

## Módulos

### 📊 Dashboard
- KPIs en tiempo real: stock bajo mínimo, alertas de vencimiento, ventas del día, mermas
- Resumen del ecosistema: estado de warehouseMos y MosExpress
- Gráficos de rotación y actividad

### 📦 Catálogo
- Vista unificada agrupada por producto base + presentaciones
- **Cards con flip 3D**: click en ✏️ gira la card → precio rápido + editar completo
- **Presentaciones expandibles**: click en la card despliega todas las presentaciones debajo
- **Búsqueda inteligente**: normaliza tildes, busca por palabras sueltas, código de barra o nombre — resultados ordenados por relevancia (scoring tipo Google)
- **Cache local**: carga instantánea desde localStorage, refresco en background cada 30 min
- **Actualizaciones optimistas**: el precio se refleja en UI antes de confirmar con el servidor
- Badges: categoría, ⚗️ Envasable, N presentaciones, Inactivo
- Estructura: 1 fila base (idProducto = skuBase) + 1 fila por presentación con factorConversion

### 🏭 Almacén
- Stock en tiempo real desde warehouseMos
- Alertas de vencimiento crítico y próximo
- Historial de mermas
- Registro de envasados

### 🤝 Proveedores
- CRUD de proveedores maestros
- Registro de pagos con historial
- Gestión de pedidos por proveedor

### 🗃️ Cajas (MosExpress)
- Estado en tiempo real de todas las cajas abiertas
- KPIs del día: total vendido, tickets, anulados, sin cobrar
- Gráfico de ventas por cajero y métodos de pago
- Historial de cierres (últimos 30 días)
- Link a reporte HTML de cierre por caja

### ⚙️ Configuración *(solo rol master)*
- **Estaciones**: CRUD de estaciones ME y WH, PINs de acceso
- **Impresoras**: gestión de impresoras PrintNode por app
- **Personal**:
  - Usuarios MOS (roles: `master` / `admin`) con PIN de acceso
  - Operadores warehouseMos (PIN, rol, tarifa)
- **Series documentales**: NV / Boleta / Factura por estación
- **Seguridad**: PINs de estaciones y acceso WH

---

## Autenticación

Login con PIN al iniciar la app (igual que warehouseMos):
1. Selecciona tu perfil
2. Ingresa PIN de 4–6 dígitos
3. Sesión persiste en `localStorage` — no pide PIN en cada visita

### Roles
| Rol | Acceso |
|---|---|
| `master` | Todo incluyendo Configuración |
| `admin` | Todo excepto Configuración |

**Primera vez**: agrega el usuario directamente en la hoja `PERSONAL_MASTER` del Google Sheet de MOS con `appOrigen = MOS` y `rol = master`.

---

## Estructura del repositorio

```
index.html          ← App completa (HTML + CSS + estructura)
js/
  api.js            ← Wrapper HTTP hacia GAS (URL hardcodeada)
  app.js            ← Toda la lógica: navegación, vistas, modales, charts
gas/
  Code.gs           ← Router principal doGet/doPost
  Config.gs         ← CRUD: estaciones, impresoras, personal, series
  Productos.gs      ← CRUD catálogo maestro + precios
  Proveedores.gs    ← CRUD proveedores + pagos + pedidos
  Conexiones.gs     ← Gestión de URLs cross-app
  Cajas.gs          ← Consulta estado cajas MosExpress
  Migracion.gs      ← Script one-time: importa catálogo desde MosExpress
  Setup.gs          ← Inicialización del Spreadsheet
manifest.json
sw.js               ← (pendiente)
```

---

## GAS — Deploy

1. Abre el proyecto en [Google Apps Script](https://script.google.com)
2. **Implementar → Nueva implementación → Web App**
   - Ejecutar como: **Yo**
   - Acceso: **Cualquier persona**
3. La URL generada va hardcodeada en `js/api.js` → `GAS_URL`
4. En cada actualización de código GAS: **Administrar implementaciones → editar → Nueva versión → Implementar**

---

## Google Sheet — Hojas requeridas

| Hoja | Descripción |
|---|---|
| `PRODUCTOS_MASTER` | Catálogo unificado (bases + presentaciones) |
| `EQUIVALENCIAS` | Alias de códigos de barra |
| `ESTACIONES` | Estaciones ME y WH |
| `IMPRESORAS` | Impresoras PrintNode |
| `PERSONAL_MASTER` | Operadores WH + usuarios MOS |
| `SERIES_DOCUMENTALES` | Series NV/Boleta/Factura |
| `PROVEEDORES` | Maestro de proveedores |
| `PAGOS_PROVEEDOR` | Historial de pagos |
| `PEDIDOS_PROVEEDOR` | Pedidos a proveedores |
| `CONEXIONES` | URLs GAS de apps conectadas |
| `CONFIG_MOS` | Parámetros de configuración |
| `HISTORIAL_PRECIOS` | Log de cambios de precio |

Ejecuta `setupMOS()` desde GAS para crear todas las hojas automáticamente.

---

## Push Notifications (FCM)

Las notificaciones push usan **Firebase Cloud Messaging v1 API**. Los tokens de dispositivo se guardan en la hoja `PUSH_TOKENS` del Google Sheet de MOS.

### Eventos que disparan push

| # | Evento | Archivo GAS | Función |
|---|--------|-------------|---------|
| 1 | Login MOS | `js/app.js` | `confirmarPin()` |
| 2 | Login warehouseMos | `warehouseMos/gas/Personal.gs` | `_notificarMOS()` |
| 3 | Cierre de caja (MosExpress) | `MosExpress/gas/Caja.gs` | `procesarCierreCaja()` |
| 4 | Nuevo preingreso (warehouseMos) | `warehouseMos/gas/Productos.gs` | `crearPreingreso()` |
| 5 | Resumen diario automático (10 PM) | `gas/Push.gs` | `enviarResumenDiario()` |

### Agregar un nuevo push

En cualquier función GAS de los 3 proyectos, agrega:
```js
_notificarMOS('🔔 Título', 'Cuerpo del mensaje');
```
Asegúrate de que `_notificarMOS()` esté definida en ese archivo GAS (copia la función de `Personal.gs` o `Caja.gs`).

### Activar el resumen diario

Corre **una sola vez** desde el editor GAS de ProyectoMOS:
```
configurarTriggerResumen()
```
Esto crea un trigger que ejecuta `enviarResumenDiario()` todos los días a las 10 PM.

### Script Properties requeridas (ProyectoMOS GAS)

| Clave | Valor |
|---|---|
| `FCM_PROJECT_ID` | `proyectomos-push` |
| `FCM_CLIENT_EMAIL` | email del service account de Firebase |
| `FCM_PRIVATE_KEY` | clave privada del service account |

---

## Ecosistema

```
MOS Admin (este repo)
├── lee stock, mermas, envasados ← warehouseMos
├── lee ventas, cajas            ← MosExpress
└── publica precios              → ambas apps
```

Las URLs de conexión se configuran en **Configuración → Conexiones** (hoja `CONEXIONES`).
