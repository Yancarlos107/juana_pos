# Lista de Prioridades — Juana POS

**Fecha:** 2026-07-05
**Fuentes:** `AUDITORIA_v1.10.10.md` (bugs concretos) + `BLINDAJE_APLICACION.md` (patrones estructurales)
**Orden:** primero los errores que reportó el operador, luego los encontrados en la auditoría.

**Leyenda:** Impacto 🔴 crítico · 🟠 alto · 🟡 medio · 🔵 bajo | Esfuerzo: S pequeño · M medio · L grande (refactor)

---

## ✅ TIER 0 — Ya resuelto (solo para constancia)

| Qué | Origen | Estado |
|-----|--------|--------|
| Pantalla negra en el **primer login** (race condition AuthGate/LoginScreen) | **Reportado por ti** | ✅ Corregido en v1.10.9 / v1.10.10 |

---

## 🥇 TIER 1 — Errores que TÚ reportaste (máxima prioridad)

| # | Qué | Ref | Impacto | Esfuerzo | Nota |
|---|-----|-----|---------|----------|------|
| **P1** | **Punto de venta congelado en el dashboard.** El POS cambia en el servidor pero el header sigue mostrando el viejo; ventas y cierre usan el nuevo. Al reingresar sale bien. | C1 | 🔴 | M | Sigue presente en v1.10.10. Causa: el header lee el POS 1 sola vez en `initState` y el timer de 5 min lo cambia por detrás. |
| **P2** | **Pantalla negra en el cierre de caja.** | C2 | 🔴 | S (parche) / L (raíz) | Parche inmediato: inicializar las 3 variables `null` como listas vacías. Raíz: sacar la navegación imperativa del cierre. |

---

## 🥈 TIER 2 — Críticos que encontré (atacar enseguida)

| # | Qué | Ref | Impacto | Esfuerzo | Nota |
|---|-----|-----|---------|----------|------|
| **P3** | **Pérdida de dinero: el mantenimiento borra ventas no sincronizadas.** Tras 3 días, `db.delete('transactions')` borra hasta las `pending`. Tablet sin red 3+ días = ventas perdidas. | Blindaje 🔴 | 🔴 | S | **El más severo técnicamente.** Fix pequeño: no borrar `status='pending'` / `server_id IS NULL`. |
| **P4** | **El sync de fondo borra la tabla `users` y pisa el hash del PIN cada 5 min.** Rompe el login offline por PIN y causa race en lecturas de cajero. | C3 | 🔴 | M | Quitar `batch.delete('users')`; no sobreescribir el hash local asegurado. |

> Aunque respeté tu orden (tus reportes primero), quiero ser claro: **P3 es probablemente el
> hallazgo más grave de todos** porque es pérdida de dinero silenciosa. No debería esperar mucho.

---

## 🥉 TIER 3 — Altos

| # | Qué | Ref | Impacto | Esfuerzo | Nota |
|---|-----|-----|---------|----------|------|
| **P5** | **Descuadre de cierre con turnos compartidos.** La confirmación suma ventas de todos los cajeros; solo se cierran las del actual. | A1 | 🟠 | S | Añadir `AND cashier_id = ?` a la query de `showClosingConfirmation`. |
| **P6** | **Las sesiones nunca se sincronizan al backend.** API comentada + el cierre nunca marca la sesión `closed`. | A2 | 🟠 | M | Requiere endpoint backend + cerrar la sesión en `performClosing`. |
| **P7** | **Producción por HTTP plano + certificado sin validar.** Token, PIN y QR viajan sin cifrar. | A3 | 🟠 | M | Depende de infra del servidor (HTTPS), no solo de la app. |

---

## 🏗️ TIER 4 — Blindaje estructural (refactors que colapsan familias de bugs)

Estos no son un bug puntual; son los **patrones raíz**. Atacarlos elimina varias fallas a la vez.

| # | Patrón | Ref | Impacto | Esfuerzo | Qué resuelve de paso |
|---|--------|-----|---------|----------|----------------------|
| **P8** | **Separar el monitor de las mutaciones.** Sacar `initializePOS`/wipe de users del timer de 5s. | Patrón B | 🔴 | M | Arregla P1 (C1), P4 (C3) y el modal OTA intrusivo de una sola vez. |
| **P9** | **Una fuente de verdad para POS y cajero** (providers con `ref.watch`, no copias a campos locales). | Patrón A | 🟠 | M | Refuerza P1; elimina la deriva de datos. |
| **P10** | **Un solo paradigma de navegación** (el estado de auth decide la pantalla; fuera navegación imperativa en login/cierre). | Patrón E | 🟠 | L | Raíz de P2 y de la familia de pantallas negras. |
| **P11** | **Atomicidad** — cada operación de negocio en una transacción; datos emparejados (POS id+nombre) juntos. | Patrón C | 🟠 | M | Cierra la puerta al origen histórico del bug del POS. |
| **P12** | **Hardware fuera de la ruta crítica** — persistir primero, imprimir/abrir torniquete después. | Patrón F | 🟠 | M | Que un fallo de impresora no rompa venta/cierre. |
| **P13** | **Endurecer el esquema de BD** — estados excluyentes, `session_id`/`cashier_id` no nulos, dinero en enteros. | Patrón H | 🟡 | L | Elimina el `OR session_id IS NULL` y la atribución al cajero 1. |

---

## 🧹 TIER 5 — Medios y bajos (limpieza / higiene)

| # | Qué | Ref | Impacto | Esfuerzo |
|---|-----|-----|---------|----------|
| P14 | Retirar código muerto peligroso: `SyncService` (`HASH_TEMPORAL`), `ClosureService`, `SessionService.closeSession` | M1 / Blindaje | 🟡 | S |
| P15 | `initializePOS()` sin guard de concurrencia (login + timer pueden solaparse) | M3 | 🟡 | S |
| P16 | Deduplicar: moneda (4 copias), device-info (2 que dan `ime` distinto), UTC-5 (3), agregación de ventas (4) | Patrón G / M4 | 🟡 | M |
| P17 | OTA disparado desde `dispose()` con delay arbitrario | M2 | 🟡 | S |
| P18 | `search()` inconsistente con `_fetchHistory` (sin `cashier_id`, `is_closed` distinto) | M5 | 🟡 | S |
| P19 | IPs LAN hardcodeadas con polling (cámara cada 5s, PMR) | M6 | 🟡 | M |
| P20 | Dinero como `double` (redondeo en cuadres) — incluido en P13 si se hace el esquema | M7 | 🟡 | M |
| P21 | Logs sensibles (`print` de payloads/token) activos en producción | B2 | 🔵 | S |
| P22 | `clearAll()` no limpia POS id/name; query muerta `userRows`; interceptor 401 sin implementar; SHA-1; `reviewer_code` en texto plano | B1/B3/B4/B5/B7 | 🔵 | S |

---

## Orden de ejecución sugerido

**Ronda 1 — Parar la sangría (fixes pequeños, alto impacto, bajo riesgo):**
`P3` (pérdida de datos) → `P2 parche` (pantalla negra: init de las 3 listas) → `P5` (descuadre cierre) → `P14` (borrar código muerto) → `P21` (silenciar logs de prod).

**Ronda 2 — Los reportes de fondo:**
`P8` (separar monitor de mutaciones) — esto arregla `P1` y `P4` juntos → `P9` (fuente única para POS).

**Ronda 3 — Blindaje mayor (refactors con más test):**
`P10` (navegación) → `P11` (atomicidad) → `P12` (hardware) → `P13` (esquema).

**Ronda 4 — Higiene y coordinación externa:**
`P6` y `P7` (necesitan backend) → `P16`–`P20` (dedupe y limpieza).

> Regla guía: en las rondas 1–2 se corrigen **síntomas** para estabilizar ya; en las rondas 3–4
> se corrigen **patrones** para que no vuelvan a aparecer.
