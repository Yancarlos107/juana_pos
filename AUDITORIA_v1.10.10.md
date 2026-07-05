# Auditoría Exhaustiva — Juana POS v1.10.10

**Fecha:** 2026-07-05
**Rama:** `feature/epson-printer`
**Alcance:** Revisión completa de los 39 archivos de `lib/` (auth, sales, sync, monitoring, printer, core)
**Auditor:** Claude Code (Opus 4.8)

---

## 🔴 CRÍTICOS

### C1. El punto de venta del dashboard queda "congelado" (EL BUG REPORTADO — SIGUE PRESENTE)

**Archivos:** `dashboard_screen.dart:57`, `system_status_service.dart:70`, `init_service.dart:116-129`

**Este es exactamente el bug que reportaste:** el POS se actualizó por archivo de configuración en el servidor, pero el dashboard siguió mostrando el punto de venta viejo, mientras las ventas y el cierre sí usaron el nuevo.

**Cadena causal confirmada:**

1. `SystemStatusNotifier` corre un `Timer.periodic` cada 5 segundos. Si hay internet y pasaron ≥5 minutos desde el último sync, llama a `initializePOS()` **durante la sesión activa** (`system_status_service.dart:66-74`):
   ```dart
   if (_lastConfigSync == null || now.difference(_lastConfigSync!).inMinutes >= 5) {
     _lastConfigSync = now;
     await _initService.initializePOS();   // ← corre con el dashboard abierto
   }
   ```

2. `initializePOS()` procesa `pos_assign_pos_location` y **sobreescribe el POS guardado** (`init_service.dart:116-129`):
   ```dart
   await _storage.savePosLocationId(locId);
   await _storage.savePosLocationName(locName);   // nuevo POS en storage
   ```

3. Pero el header del dashboard lee `_posName` **una sola vez** en `initState()` y nunca lo refresca (`dashboard_screen.dart:56-62`):
   ```dart
   final posName = await storage.getPosLocationName();
   _posName = posName ?? ... ;   // se lee 1 vez, jamás se vuelve a leer
   ```

4. En cambio, cada venta (`sales_providers.dart:247`), cada ticket (`dashboard_screen.dart:205`) y el cierre (`closing_helper.dart:1026`) leen `getPosLocationId()/getPosLocationName()` **en tiempo real** → obtienen el POS nuevo.

**Resultado:** header viejo, ventas/cierre nuevos. **Y al reingresar sí sale correcto** porque `initState()` vuelve a correr y relee el storage. Coincide 100% con el síntoma reportado.

**Fix:** El header no debe ser un campo de estado leído una vez. Opciones:
- Exponer el POS name vía un `StateProvider`/`StateNotifier` que se actualice cuando `initializePOS()` cambie el POS, y hacer `ref.watch` en el `build()` del dashboard.
- O como mínimo, releer `_posName` en `didChangeDependencies` / al cambiar de pestaña.

---

### C2. Crash (pantalla negra) en el cierre de caja por variables null

**Archivo:** `closing_helper.dart:885, 900, 914, 933-949`

Tres variables se declaran **sin tipo y sin valor inicial**. Si su query lanza excepción, el `catch` solo imprime y la variable queda `null`:

```dart
var unclosedAgg;                    // null si el query falla
try { unclosedAgg = await db.rawQuery(...); }
catch (e) { print('Error...'); }   // se traga el error → sigue null

var pmrSales;                        // idem
var reprintsResult;                  // idem

// Más abajo, SIN protección:
int pmrCount = pmrSales.length;                       // línea 933 → NoSuchMethodError
int reprintsCount = (reprintsResult.first['c'] ...);  // línea 934 → crash
for (var sale in pmrSales) { ... }                    // línea 939 → crash
for (final row in unclosedAgg) { ... }                // línea 949 → crash
```

Cuando esto crashea, la excepción sube al `catch` de `performClosing` (línea 1185), que ejecuta:
```dart
Navigator.of(context).popUntil((route) => route.isFirst || ...);
```
sobre un `context` que puede venir de un diálogo ya destruido (viene de `CashCountScreen` dentro del `IndexedStack`). **Este es el candidato más probable de la "pantalla negra en el cierre" que reportaste.**

**Fix:**
```dart
List<Map<String, dynamic>> unclosedAgg = [];
List<Map<String, dynamic>> pmrSales = [];
List<Map<String, dynamic>> reprintsResult = [];
```

---

### C3. El sync en segundo plano borra la tabla `users` y pisa el hash del PIN cada 5 minutos

**Archivo:** `init_service.dart:76`, disparado desde `system_status_service.dart:70`

`initializePOS()` ejecuta **incondicionalmente** en cada llamada:
```dart
batch.delete('users');   // borra TODOS los usuarios
// ...y reinserta desde el servidor con:
'password_hash': u['device_login_password'],  // hash del servidor
```

Como el timer de 5 min llama a `initializePOS()`, esto ocurre **durante la operación normal**. Consecuencias:

1. **Rompe el login offline por PIN.** En el primer login, `login_screen.dart:352-388` hace "PIN assurance": guarda `sha1(pin)` como `password_hash` del usuario. Pero 5 minutos después, el `initializePOS()` de fondo **sobreescribe ese hash** con el `device_login_password` del servidor. Si el cajero intenta reingresar offline con su PIN, el hash ya no coincide → "PIN incorrecto o no autorizado" (`login_screen.dart:299-304`).

2. **Race condition en lecturas de `users`.** Ventas, cierre y RC171 consultan `users` por id para el nombre del cajero. Si el `batch.delete('users')` de fondo coincide con esas lecturas, pueden devolver "Cajero Desconocido".

**Fix:** No borrar/reinsertar toda la tabla en cada llamada. Hacer upsert por id (ya usa `ConflictAlgorithm.replace`, así que basta con quitar el `batch.delete('users')`), y **no** sobreescribir `password_hash` si ya existe un hash local asegurado.

---

## 🟠 ALTOS

### A1. La confirmación de cierre suma ventas de TODOS los cajeros, pero solo cierra las del actual

**Archivo:** `closing_helper.dart:479-489` vs `closing_helper.dart:849-853`

`showClosingConfirmation()` consulta sin filtrar por cajero:
```dart
where: '(session_id = ? OR session_id IS NULL) AND is_closed = 0 AND product_id NOT IN (...)'
// ← falta AND cashier_id = ?
```
pero `performClosing()` sí filtra `AND cashier_id = ?`. Si dos cajeros comparten la sesión del día (cambio de turno sin cerrar), el diálogo muestra el **total combinado**, el cajero confirma esa cifra, pero solo se cierran SUS ventas. Las del otro cajero quedan abiertas sin aviso y el monto confirmado no cuadra con lo realmente cerrado.

**Fix:** Añadir `AND cashier_id = ?` (con `currentCashierId`) a la query de `showClosingConfirmation`.

---

### A2. Las sesiones de caja nunca se sincronizan con el backend

**Archivos:** `background_sync_service.dart:617`, `closing_helper.dart:1141-1168`

Dos problemas combinados:
1. `_syncSessions()` tiene la llamada al API **comentada** (línea 616); solo marca `synced_closed` localmente.
2. El cierre normal (`performClosing`) **nunca cambia el status de la sesión** a `'closed'` — solo inserta el CIERRE y marca transacciones `is_closed=1`. La sesión sigue `'open'`.

Por lo tanto `_syncSessions` (que busca `status='closed'`) nunca encuentra nada. El backend no recibe información de apertura/cierre de sesión. (El cierre de ventas sí llega vía RC172, pero la sesión como entidad no.)

---

### A3. Tráfico en producción por HTTP plano + validación de certificado desactivada

**Archivos:** `api_constants.dart:5`, `dio_client.dart:32`

```dart
static const String baseUrlProd = 'http://35.208.37.141:8089/api';   // HTTP plano
// ...
client.badCertificateCallback = (cert, host, port) => true;           // acepta cualquier cert
```

Todo el tráfico (token Bearer, PIN en el login, QR de ventas, MAC del dispositivo) viaja **sin cifrar**. Un atacante en la misma red puede leer/modificar todo (MITM trivial). El `badCertificateCallback => true` además anularía cualquier protección si migraran a HTTPS.

---

## 🟡 MEDIOS

### M1. Código muerto y engañoso del cierre
**Archivos:** `closure_service.dart` (todo), `session_service.dart:58`

`ClosureService.closeRegister()`, `ClosureService.openRegister()` y `SessionService.closeSession()` **no se invocan en ningún lado** (confirmado por grep). El README dice que el cierre pasa por `ClosureService`, pero el flujo real es `ClosingHelper` + `background_sync_service`. Riesgo: alguien podría re-cablear la ruta equivocada y provocar cierres duplicados. Eliminar o documentar como obsoleto.

### M2. Modal OTA disparado desde `dispose()`
**Archivo:** `location_selection_dialog.dart:31-37`
Se programa el modal OTA con `Future.delayed(1000ms)` dentro del `dispose()` del diálogo, justo cuando se navega al dashboard. Delay arbitrario que puede colisionar con la inicialización del dashboard. Mejor dispararlo tras confirmar la navegación.

### M3. `initializePOS()` sin guard de concurrencia
**Archivo:** `init_service.dart:29`
La llamada del login (`location_selection_dialog`) y la del timer de 5 min pueden solaparse. Ambas ejecutan `batch.delete('users')`. No hay un flag `_isInitializing` como sí lo tiene `syncPendingData`. Añadir guard.

### M4. Offset UTC-5 hardcodeado en 3 lugares
**Archivos:** `closing_helper.dart:981`, `printer_service.dart:322`, `epson_epos_service.dart:44`
```dart
final now = DateTime.now().toUtc().subtract(const Duration(hours: 5));
```
Además `now.toIso8601String()` se guarda **sin sufijo de zona**, quedando ambiguo en el backend. En Colombia (UTC-5 sin DST) funciona hoy, pero es frágil. Preferir `DateTime.now()` local o incluir el offset.

### M5. `search()` inconsistente con `_fetchHistory()`
**Archivo:** `sales_providers.dart:451-492`
`search()` no filtra por `cashier_id` (sí lo hace `_fetchHistory`) y calcula `is_closed` de forma distinta (`session_id != openSessionId` vs el flag real de la BD). Puede mostrar ventas de otros cajeros y estados de cierre incorrectos.

### M6. IPs LAN hardcodeadas con polling constante
**Archivos:** `system_status_service.dart:151` (`http://192.168.1.101` cada 5 s), `dashboard_screen.dart:1193` (`http://192.168.1.100/open-pmr`)
El chequeo de cámara pega a una IP fija cada 5 segundos con timeout de 2 s; si no está, desperdicia ciclos constantemente. Deberían ser configurables.

### M7. Dinero manejado como `double` (punto flotante)
**Archivos:** esquema `transactions.amount REAL`, sumas en `closing_helper.dart`, `closure_service.dart`
Los totales de caja se acumulan con `double` (`totalAmount += amount`, `SUM(amount)`). Para montos con decimales puede introducir errores de redondeo en el cuadre. Considerar enteros (centavos) o `Decimal`.

---

## 🔵 BAJOS

| # | Archivo | Descripción |
|---|---------|-------------|
| B1 | `dashboard_screen.dart:212` | Query muerta `userRows = await db.query('users', limit:1)` en cada impresión; el resultado nunca se usa. |
| B2 | `background_sync_service.dart:160`, `dio_client.dart:69,76-78` | `print()` de payloads sensibles (QR, MAC, token, body completo) activos en producción → visibles en `adb logcat`. |
| B3 | `local_storage_repository.dart:226` | `clearAll()` no borra `active_pos_location_id/name` al hacer logout. |
| B4 | `dio_client.dart:80-82` | El interceptor 401 es un `TODO`; el token expirado no fuerza logout, el usuario queda con sesión muerta. |
| B5 | `auth_service.dart:60`, `login_screen.dart:294` | Hash de PIN/clave con **SHA-1** (débil) y sin salt. |
| B6 | `auth_service.dart:102-103` | `_offlineLogin` compara el hash **o el password en texto plano** contra la columna `password_hash`. |
| B7 | `dashboard_screen.dart:725` | El `reviewer_code` (PIN de fiscalizador) se compara en texto plano en la query SQL. |
| B8 | `login_screen.dart:252` | Llave DES `'juana-777'` hardcodeada para descifrar el QR de login. |
| B9 | `sync_service.dart` | Servicio completo con `HASH_TEMPORAL` y `TODO`s; parece obsoleto (el flujo real usa `init_service`). Verificar si se usa. |

---

## Respuestas directas a lo que preguntaste

**¿El bug del punto de venta ya está bien en esta versión?**
**No.** Sigue presente (ver C1). El header del dashboard se lee una sola vez en `initState()` y el timer de 5 minutos (`system_status_service.dart:70`) actualiza el POS por detrás sin que el header se entere. Por eso ventas y cierre salían con el POS nuevo y el dashboard con el viejo, y al reingresar salía correcto.

**¿Por qué la pantalla negra en el cierre?**
El candidato más fuerte es C2: si cualquiera de los tres queries de `performClosing` falla, las variables `null` provocan un crash, y el `catch` hace `popUntil` sobre un contexto de diálogo ya muerto (dentro del `IndexedStack`), dejando la pantalla en negro.

---

## Prioridad de corrección sugerida

1. **C1** — el bug reportado del POS (visible al operador, afecta trazabilidad de ventas).
2. **C2** — pantalla negra en cierre (bloquea al cajero).
3. **C3** — el sync de fondo rompe el PIN offline y pisa datos.
4. **A1** — cuadre de caja incorrecto con turnos compartidos.
5. Resto según ventana de mantenimiento.
