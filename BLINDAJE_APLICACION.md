# Blindaje de la Aplicación — Revisión Estructural

**Fecha:** 2026-07-05
**Objetivo:** No cazar bugs sueltos, sino encontrar los **patrones estructurales** que hacen
que la app sea propensa a fallar, para dejarla blindada y funcionando de forma predecible.
**Método:** El mismo lente de "por qué falla el cierre", aplicado a los 39 archivos de `lib/`.

> La idea central: la mayoría de los fallos de esta app **no son bugs independientes**,
> son **el mismo patrón repetido en distintos módulos**. Si se corrige el patrón, desaparecen
> familias enteras de fallos a la vez.

---

## 🔴 RIESGO NUEVO Y GRAVE — Pérdida de datos (dinero) por mantenimiento

**Archivos:** `database_maintenance_service.dart:85-95`, disparado desde `login_screen.dart:55`

`runMaintenance()` corre en **cada login**. Si pasaron ≥3 días desde la última limpieza:
1. Exporta TODAS las transacciones a un `.txt`.
2. Ejecuta `db.delete('transactions')` **sin mirar el estado**.

```dart
static Future<void> _clearTransactions() async {
  int count = await db.delete('transactions');   // ← borra TODO, incluidas status='pending'
}
```

**Escenario de pérdida real:** una tablet sin internet por 3+ días (SIM caída, zona sin señal).
Sus ventas están en `status='pending'` esperando sincronizar. Al reingresar, el mantenimiento
las **borra** dejándolas solo en un archivo de texto que el servidor nunca leerá.
**Dinero cobrado que desaparece del sistema.**

**Cómo blindar:** nunca borrar transacciones con `status='pending'` o `server_id IS NULL`.
El backup a `.txt` no es un respaldo válido de datos transaccionales; el criterio de borrado
debe ser "ya confirmada por el servidor", no "ya pasaron 3 días".

---

## Los 8 patrones estructurales de fragilidad

### A. Estado disperso sin una única fuente de verdad

El mismo dato vive en **4 lugares** que se desincronizan entre sí:

| Almacén | Ejemplos |
|---------|----------|
| SQLite | `transactions`, `users`, `sessions`, `products` |
| SharedPreferences | pos_location, branch_id, roles, balance, gps, mac, first_login, listas cacheadas |
| SecureStorage | token, token_validator |
| Riverpod (memoria) | authProvider.user, balanceProvider, reviewerNameProvider |

**Casos concretos de deriva:**
- El nombre del POS: campo `_posName` (widget) vs `active_pos_location_name` (prefs) vs asignación real del servidor → **es el bug C1 del dashboard**.
- El cajero: `authProvider.user` (memoria) vs `active_cashier_id` (prefs) vs tabla `users` (SQLite). `restoreOfflineUser` intenta reconciliar 3 fuentes a mano.
- El hash del PIN: `device_login_password` del servidor vs `sha1(pin)` local asegurado → **es el bug C3**.

**Por qué falla:** cada pantalla reconcilia estas fuentes manualmente y **de forma distinta**.
Cuando una se actualiza y otra no, la app muestra/usa datos contradictorios.

**Cómo blindar:** una sola fuente de verdad por dato, expuesta por un provider, y que todos
lean de ahí (`ref.watch`) en vez de copiar el valor a campos locales.

---

### B. El monitor de 5 segundos es un motor de mutaciones peligrosas

**Archivo:** `system_status_service.dart:37-88`

`SystemStatusNotifier` corre un `Timer.periodic` cada 5s que **no solo observa, sino que muta estado crítico**:
- Dispara `syncPendingData()` (escribe en BD) en **cada** ping exitoso (cada 5s).
- Cada 5 min llama a `initializePOS()` → `batch.delete('users')`, cambia el POS, puede abrir el modal OTA.
- Pega a una IP LAN fija cada 5s (cámara).

**Por qué falla:** un bucle de monitoreo debería ser **de solo lectura**. Aquí ejecuta borrados
de tabla, cambios de punto de venta y pop-ups **sin importar qué esté haciendo el cajero**.
Es el motor detrás de C1 (POS congelado) y C3 (hash pisado). Un modal OTA puede saltar en
mitad de una venta.

**Cómo blindar:** separar "monitorear" (leer estado, actualizar indicadores) de "sincronizar/
configurar" (mutar). Lo que muta debe correr en momentos seguros y con guardas de concurrencia,
no en un timer ciego de 5s.

---

### C. Operaciones multi-paso sin atomicidad

Muchas operaciones tocan varios almacenes en secuencia; si fallan a la mitad, dejan estado parcial.

**Casos concretos:**
- Login: escribe token (secure) → branch/roles/balance (prefs) → user (SQLite) → sesión. Un fallo intermedio deja sesión a medias.
- `savePosLocationId` y `savePosLocationName` son **dos `await` separados**: si uno falla, el ID y el nombre divergen. **Ese es el origen histórico del bug del POS.**
- `fetchProducts` hace `db.delete('products')` y luego re-inserta uno por uno, **sin transacción**. Si la app muere en medio, la tabla de tarifas queda vacía → "sin tarifas" offline.
- `initializePOS` hace `batch.delete('users')` + reinsert; el batch es atómico, pero pisa el hash (ver C3).

**Por qué falla:** sin transacción, un corte de energía / cierre de app / excepción a mitad
deja la BD en un estado imposible que ninguna pantalla espera.

**Cómo blindar:** agrupar cada operación de negocio en una sola transacción de BD; para datos
emparejados (id+nombre del POS) guardarlos juntos o no guardarlos.

---

### D. Errores que se tragan y degradan a datos corruptos

El patrón `catch (_) {}` / `catch (e) { print(...) }` está por toda la app y **convierte fallos
en datos silenciosamente incorrectos**, no en errores visibles.

**Casos concretos:**
- `restoreOfflineUser` → `catch (e) { /* Fallback silencioso */ }`: si falla, el usuario queda `null` sin aviso.
- `getMacAddress`, `_getDeviceInfo` → varios `catch (_) {}`: MAC vacía o "UNKNOWN" se envía al servidor como identidad del dispositivo.
- `performClosing` → los `catch` que dejan variables en `null` (bug C2, la pantalla negra).
- `cashier_id DEFAULT 1`: una venta sin cajero conocido se **atribuye silenciosamente al cajero 1**.

**Por qué falla:** la app "sigue funcionando" pero con contexto corrupto (MAC vacía, "Cajero
Desconocido", saldo 0, POS null). El fallo aparece mucho después y lejos de su causa.

**Cómo blindar:** distinguir errores esperados (sin red → modo offline) de inesperados
(query que falla → debe propagarse y mostrarse). Nunca continuar con una variable en un estado
que el resto del código asume válido.

---

### E. Navegación imperativa cruzando ciclos de vida

**Archivos:** `login_screen.dart`, `closing_helper.dart`, `dashboard_screen.dart`, `main.dart`

Conviven **dos paradigmas de navegación peleándose**:
- Declarativo: `AuthGate` con `ref.watch(authProvider)` decide login vs dashboard.
- Imperativo: `pushReplacementNamed`, `pushNamedAndRemoveUntil`, `popUntil`, `navigatorKey.currentContext`.

Mezclados con guardas `if (mounted)` y `showDialog` sobre contextos que ya pueden estar muertos.

**Por qué falla:** cuando `authProvider` cambia Y además se navega a mano, dos mecanismos
mueven el árbol de widgets al mismo tiempo. De ahí salen las pantallas negras (la del primer
login ya corregida, y la del cierre, C2).

**Cómo blindar:** elegir UN paradigma. Lo más robusto: que el cambio de estado de auth sea el
ÚNICO que decide qué pantalla se muestra, y eliminar la navegación imperativa de los flujos de
login/logout/cierre.

---

### F. Hardware y recursos externos en la ruta crítica

Dependencias externas que pueden colgarse o fallar están **en línea** con flujos críticos:

| Recurso | Dónde | Riesgo |
|---------|-------|--------|
| Impresora USB | ventas y cierre | Un fallo de impresión interrumpe la transición de estado |
| IP cámara `192.168.1.101` | monitor cada 5s | Timeout de 2s cada ciclo si no está |
| PMR `192.168.1.100` | apertura PMR | Cuelga la apertura si no responde |
| GPS | login | Timeout de 5s bloquea el login |

**Por qué falla:** el estado de negocio (venta guardada, caja cerrada) queda acoplado a que un
periférico físico responda. Un cabezal dormido no debería impedir registrar una venta.

**Cómo blindar:** los efectos de hardware deben ser **asíncronos y no bloqueantes** respecto al
dato. Primero se persiste el hecho de negocio; imprimir/abrir torniquete es un efecto posterior
que puede reintentarse sin deshacer nada.

---

### G. Duplicación de lógica que diverge

La misma regla está copiada en varios sitios y **se desincroniza**:

| Lógica | Copias | Divergencia |
|--------|--------|-------------|
| Formato de moneda | `CurrencyFormatter` + `closing_helper` + `dashboard` + `recaudo` | 4 implementaciones idénticas a mano |
| Info del dispositivo | `background_sync._getDeviceInfo` (usa MAC) vs `closure_service._getDeviceInfo` (usa `build.id`) | **Devuelven `ime` distinto** |
| Agregación de ventas | 4 lugares en `closing_helper` | Unos filtran `cashier_id`, otros no → **bug A1** |
| Offset UTC-5 | `closing_helper` + `printer_service` + `epson_epos_service` | 3 copias del `-5h` |
| Resolución del nombre POS | repetida en dashboard, recaudo, cierre, ventas | `posName ?? branchName ?? default` copiado |

**Por qué falla:** cuando la misma regla se escribe N veces, tarde o temprano divergen y
producen resultados distintos para lo mismo (moneda, identidad del dispositivo, totales).

**Cómo blindar:** una sola función/utilidad por regla, importada en todos lados.

---

### H. Esquema de BD que permite estados ambiguos

**Archivo:** `database_helper.dart`

- `session_id` **nullable** → ventas huérfanas → **cada** query lleva `OR session_id IS NULL` (parche recurrente).
- **Tres campos de estado que se solapan**: `transactions.status`, `transactions.is_closed`, `sessions.status`. Ninguno es la verdad completa por sí solo.
- `cashier_id INTEGER DEFAULT 1` → atribución silenciosa al cajero 1.
- `amount REAL` → dinero en punto flotante, riesgo de redondeo en cuadres.

**Por qué falla:** el esquema permite combinaciones que el código no espera (venta sin sesión,
venta cerrada pero pendiente, etc.), y cada query tiene que defenderse de todas ellas.

**Cómo blindar:** estados mutuamente excluyentes en un solo campo, `session_id` no nulo,
`cashier_id` obligatorio, y dinero en enteros (centavos).

---

## Código muerto peligroso (retirar)

| Archivo | Problema |
|---------|----------|
| `sync_service.dart` | `syncInitialData()` nunca se llama, pero escribe `password_hash: 'HASH_TEMPORAL'`. Si alguien lo cablea, corrompe el login. |
| `closure_service.dart` | `closeRegister`/`openRegister` nunca se llaman; el README dice que el cierre pasa por aquí (mentira). Riesgo de cablear la ruta equivocada. |
| `session_service.dart:58` | `closeSession()` nunca se llama; cierra sesiones sin filtrar `branch_id`. |

**Por qué importa para el blindaje:** el código muerto engaña a quien mantiene la app y ofrece
rutas alternativas que hacen cosas peligrosas. Retirarlo reduce la superficie de fallo.

---

## Hoja de ruta de blindaje (por impacto)

1. **Mantenimiento de BD** — no borrar transacciones `pending`. (Pérdida de dinero.)
2. **Separar el monitor de las mutaciones** — sacar `initializePOS`/wipe de users del timer de 5s. (Arregla C1 + C3 + modal OTA intrusivo de una vez.)
3. **Una fuente de verdad para POS y cajero** — providers observados con `ref.watch`. (Familia A.)
4. **Un solo paradigma de navegación** — el estado de auth decide la pantalla; fuera navegación imperativa en login/cierre. (Familia E → pantallas negras.)
5. **Atomicidad** — cada operación de negocio en una transacción; datos emparejados juntos. (Familia C.)
6. **Hardware fuera de la ruta crítica** — persistir primero, imprimir/abrir después. (Familia F.)
7. **Deduplicar** moneda, device-info, agregación, UTC-5. (Familia G.)
8. **Retirar código muerto** peligroso. (SyncService, ClosureService, closeSession.)
9. **Endurecer el esquema** — estados excluyentes, `session_id`/`cashier_id` no nulos, dinero en enteros. (Familia H.)

> Nota: la mayoría de los bugs concretos de `AUDITORIA_v1.10.10.md` son **instancias** de estos
> patrones. Corregir el patrón (no solo el síntoma) es lo que blinda la app.
