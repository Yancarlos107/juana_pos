# Juana Sistema POS (Red de Recarga)

Aplicación Flutter para puntos de venta de la red de recarga Juana. Gestiona ventas de tickets QR, cierre de caja, impresión térmica y operación offline.

---

## Estado del Proyecto

| Ítem | Detalle |
|------|---------|
| Versión | 1.11.0 |
| Rama principal | `main` |
| Rama activa | `feature/epson-printer` |
| Compilación | Sin errores |

---

## Funcionalidades Implementadas

### Login y Autenticación
- Login online contra API (`POST /cashier-login`) con token Sanctum.
- Login offline: credenciales se guardan en SQLite tras el primer login exitoso; se valida usuario y contraseña sin red.
- Al logout, se borran solo datos de sesión activa (no los cachés offline).

### Selección de Punto de Venta
- Diálogo post-login para elegir el POS activo.
- Fallback offline: si no hay red, usa la lista de puntos guardada localmente.
- Botón CANCELAR disponible en el diálogo.

### Dashboard y Ventas
- Listado de tarifas/productos desde el servidor, con caché local.
- Venta de ticket QR: `POST /gateway/v2/purchases`.
- Detección de conexión antes de intentar la venta; flujo offline si no hay red.
- Validación de saldo local antes de cada venta.
- Balance: carga desde API con fallback al caché local si falla la red.

### Recaudo (Historial de Transacciones)
- Historial del día en SQLite, con JOIN a tabla `products` para mostrar nombre del producto.
- Reimpresión de tickets individuales desde el historial.
- Reimpresión de cierre de caja desde el historial.

### Cierre de Caja
- Resumen con desglose por tarifa, total recaudado, aperturas PMR y reimpresiones.
- Advertencia si la impresora no está conectada (con opción de continuar sin imprimir).
- Registro del cierre en SQLite como transacción `CIERRE DE CAJA`.
- Cierre automático al hacer logout si hay ventas pendientes.
- Sincronización del cierre con el servidor vía `ClosureService`.

### Impresión Térmica
- **Epson TM-T20IIIL (USB)**: Android USB Host API directo (vendor ID `0x04B8`). ESC/POS puro via `MethodChannel`. No requiere el SDK de Epson.
- **Otras impresoras USB/BT**: `flutter_thermal_printer` (detección por clase USB 7).
- `PrinterService` detecta automáticamente cuál impresora está conectada y enruta la impresión.
- Retorno `bool?`: `null` = permiso USB pendiente (usuario debe aceptar y reintentar), `true/false` = resultado.
- Ticket de venta con QR, datos del cajero, sucursal, producto y monto. Desde v1.12.x el **QR impreso** lleva un JSON en base64 con la info de la venta (`fh` fecha, `pi` pos, `t` token, `tm` tiempo de vida, `pm` PMR, `va` valor) para que el validador lo lea sin backend. Ver `lib/core/utils/sale_qr.dart`. El `qr_data` que se guarda/envía al backend sigue siendo el token aleatorio (sin cambios).
- Ticket de cierre con desglose, QR de cierre, horas PMR y total.
- Zona horaria forzada a UTC-5 (Ecuador/Colombia).

### Modo Offline
- Login con credenciales guardadas en SQLite.
- Lista de puntos de venta desde caché local.
- `updatePosSchedule` omitido silenciosamente si no hay token o hay error de red.
- Saldo y productos desde caché local.

### Monitoreo del Sistema
- Indicadores en el header: impresora, internet, PMR, transacciones pendientes.
- `checkPrinterNow()` antes de cada cierre para advertir al usuario.

---

## Arquitectura

```
lib/
├── core/
│   ├── database/       # SQLite (DatabaseHelper)
│   ├── network/        # Dio client, interceptores
│   ├── storage/        # SharedPreferences + SecureStorage
│   └── theme/
├── features/
│   ├── auth/           # Login, AuthService, AuthProvider
│   ├── monitoring/     # SystemStatusService
│   ├── printer/        # PrinterService, EpsonEposService, EpsonTestScreen
│   ├── sales/          # Dashboard, Recaudo, ClosureService, SalesProviders
│   └── sync/           # InitService
└── main.dart           # AuthGate → LoginScreen | DashboardScreen
```

```
android/
├── app/src/main/kotlin/   # MainActivity: USB Host API + MethodChannels
└── app/src/main/res/xml/  # device_filter.xml: vendor-id="1208" (Epson)
```

---

## Integración Epson TM-T20IIIL

La impresora Epson es USB clase 255 (vendor-specific), no clase 7. Por eso `flutter_thermal_printer` no la detecta y el SDK oficial de Epson causaba crashes nativos (JNI/SIGSEGV).

**Solución implementada:** Android USB Host API busca el dispositivo por vendor ID `0x04B8` (Seiko Epson Corp) directamente, abre la conexión y envía bytes ESC/POS via `bulkTransfer`. El resultado es el mismo ticket que con cualquier otra impresora térmica.

Pantalla de prueba disponible en la ruta `/epson-test`.

---

## Documentación Adicional

- `red-recarga-consola.md`: Endpoints API del backend y flujo de la consola web.
