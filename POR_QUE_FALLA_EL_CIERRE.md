# ¿Por qué el cierre de caja tiene tantos bugs?

**Contexto:** El cierre *parece* simple ("crear trama → enviar → actualizar estado → cerrar"),
pero en este código es un imán de bugs. Este documento explica **por qué**, sin proponer cambios todavía.

---

## En una frase

El cierre falla tanto no porque el concepto sea difícil, sino porque en este código
**una sola función (`performClosing`) es el punto de encuentro de 5 subsistemas distintos**
—base de datos, impresora física, red, navegación y logout—
**multiplicado por ~6 variantes de negocio, con la misma lógica copiada y divergiendo en 4 lugares,
y con errores que se silencian en vez de propagarse.**

Cada arreglo toca una de esas dimensiones y destapa otra.

---

## 1. El cierre no hace 4 pasos, hace ~11 y mezcla 5 subsistemas

Tu modelo mental ("crear trama, enviar, actualizar estado, cerrar") es el de un cierre de libro.
Pero `performClosing()` en la práctica orquesta:

1. Consulta de ventas no cerradas (BD)
2. Agregación por producto / PMR / reimpresiones (BD)
3. Construcción del payload QR base64 (lógica)
4. "Arrastre" / resumen del día (BD + lógica)
5. Modo fiscalizador vs cajero (estado global)
6. **Impresión del tiquete** (hardware USB)
7. Impresora desconectada / permiso USB / reintentos (hardware)
8. Inserción del CIERRE (BD)
9. Marcado `is_closed=1` de todas las ventas (BD)
10. **Sync con el servidor** (red)
11. **Logout + navegación a login** (ciclo de vida de widgets)

Eso es **base de datos + impresora física + red + navegación + autenticación** en una sola función.
Cada subsistema falla de forma independiente, y aquí están entrelazados: un fallo de impresora
puede dejar a medias una transición de estado de BD y una navegación.

---

## 2. Es offline-first, así que "enviar al servidor" NO es parte del cierre

En un cierre normal, "enviar la trama al servidor" es un paso. Aquí **no lo es**:
el cierre solo escribe en SQLite con `status: 'pending'` y confía en que
`background_sync_service` la mande después (RC172).

El cierre queda **desacoplado de la confirmación del servidor**, y para representar los
estados intermedios hay **tres máquinas de estado paralelas** para la misma realidad:

- `transactions.status` → `'pending'` / `'synced'`
- `transactions.is_closed` → `0` / `1`
- `sessions.status` → `'open'` / `'closed'` / `'late_closed'` / `'synced_closed'`

Se solapan y se contradicen. Ejemplo real: el cierre marca `is_closed=1` pero deja
`status='pending'` (para que el sync la mande), y **nunca** cambia `sessions.status` a `'closed'`.
Por eso las sesiones no se sincronizan: esa máquina de estado quedó huérfana del flujo.

---

## 3. El cierre está fusionado con el logout y la navegación

`isLogout` atraviesa todo el flujo. Cerrar caja = cerrar sesión = navegar a login.
**Mezclar una operación de datos con una de ciclo de vida es de donde salen las pantallas negras.**

El cierre se dispara desde `CashCountScreen`, que vive **dentro del `IndexedStack`** del dashboard.
Cuando el flujo termina y navega, el `context` original ya puede estar muerto. Por eso el código
está lleno de parches:

- `navigatorKey.currentContext ?? context`
- `popUntil((route) => route.isFirst || ...)`
- `pushNamedAndRemoveUntil('/login', ...)`
- múltiples `_showSafeLoader` con su propio `isClosed`

Todos son síntomas de que el flujo **cruza fronteras de widgets que ya no existen**.
Un cierre puro (solo datos) no necesitaría nada de eso.

---

## 4. La impresora (hardware físico) está en la ruta crítica

Imprimir es un dispositivo USB que puede estar desconectado, dormido o pedir permiso.
El cierre intenta imprimir **en medio** de la transición de estado: pide permiso USB,
si devuelve `null` hace `return` a mitad del cierre, reintenta a los 500ms, muestra diálogo...
Un fallo de impresión **no debería** romper un cierre contable, pero la estructura los hace
co-dependientes.

---

## 5. Explosión combinatoria de variantes

`performClosing` recibe `cashList, cash, balance, isArrastre, skipPrinting` + `isLogout`.
Las combinaciones:

- Cierre desde Recaudo vs desde Arqueo/CashCount
- Con arrastre vs sin arrastre
- Fiscalizador vs cajero
- Con impresora vs sin impresora
- Logout vs no logout

Son decenas de rutas posibles, y casi ninguna está testeada.
Cada arreglo de una combinación puede romper otra.

---

## 6. Lógica duplicada que diverge (el origen del bug de descuadre)

La misma agregación de ventas está **copiada** en cuatro lugares con WHERE clauses distintos:

| Lugar | ¿Filtra por `cashier_id`? |
|-------|---------------------------|
| `showClosingConfirmation` | ❌ NO |
| `performClosing` | ✅ SÍ |
| `printArqueoTicket` | ✅ SÍ |
| `_buildDaySummary` | filtra por fecha, no por sesión |

Cuando la misma regla está escrita 4 veces, **diverge**, y esa divergencia ES el bug:
la confirmación muestra un total y se cierra otro.

Además hay **dos implementaciones enteras del cierre**:
`ClosureService.closeRegister` (código muerto) y `ClosingHelper.performClosing` (la viva).
Cualquiera que toque la muerta por error introduce un cierre duplicado.

---

## 7. El manejo de errores esconde los fallos (el origen del crash / pantalla negra)

Los `try/catch` que solo hacen `print()` y siguen (dejando variables en `null`) se agregaron
para "proteger", pero convierten un fallo inmediato en un **crash diferido y silencioso**.

Y los rastros de depuración —`print("--- performClosing --- 10.41")`, `"10.42"`, `"10.5"`...—
son la firma de un módulo **depurado reactivamente a fuerza de breadcrumbs**,
apagando incendios uno por uno en vez de rediseñarse.

---

## La salida de fondo (cuando se quiera abordar)

Separar las responsabilidades:

1. **Una función pura** que calcule el cierre y devuelva un objeto (sin tocar BD, impresora ni UI).
2. **Una función** que persista ese objeto en BD de forma atómica (una sola transacción).
3. **La impresión como efecto secundario** que puede fallar sin abortar el cierre.
4. **La navegación/logout completamente afuera**, disparada por el cambio de estado de auth
   —no llamada a mano desde dentro del cierre.

Eso colapsaría la mayoría de estos bugs a la vez.
