# Tramas de impresora — RC175 / RC176

Especificación de cómo el POS (Juana POS, v1.12.5+) envía los eventos de
desconexión y conexión de la impresora, para que el backend los implemente.

| Código | Evento |
|--------|--------|
| **RC175** | Impresora **desconectada** |
| **RC176** | Impresora **conectada** (reconexión) |

## Cuándo se genera

- El POS revisa la impresora USB cada 5 segundos.
- Se genera una trama **solo cuando cambia el estado** (conectada → desconectada o al revés).
- Si la app arranca sin impresora, se genera un **RC175**. Si arranca con impresora, no se genera nada.
- El evento se guarda primero en el equipo (offline-first) y se envía después; puede llegar con minutos u horas de retraso. **La hora real del evento es `dat`**, no la hora de recepción.

## Endpoint

```
POST {baseUrl}/pos-transactions
```

Mismo endpoint y mismo formato que RC171 / RC174.

### Headers

```
Authorization: Bearer <token del POS>
Accept: application/json
Content-Type: application/json
```

### Body

```json
{
  "type_code": "RC175",
  "token": "",
  "dat": "1761314711",
  "lat": "0.0",
  "lon": "0.0",
  "hw": "TPS530",
  "ime": "A4:12:F4:3B:9C:01",
  "employee_full_name": "Juan Pérez",
  "cashier_id": "12",
  "typ": "RC175",
  "ver": "1.0.0",
  "pos_location_id": "7"
}
```

Para la conexión es igual, con `"type_code": "RC176"` y `"typ": "RC176"`.

### Campos

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `type_code` | string | `RC175` (desconexión) o `RC176` (conexión). |
| `token` | string | Siempre vacío `""`. |
| `dat` | string (número) | Fecha/hora **del evento** en unix timestamp, en **segundos**. |
| `lat` / `lon` | string | Siempre `"0.0"` (no se envía GPS en estas tramas). |
| `hw` | string | Modelo del equipo (Android `Build.MODEL`). |
| `ime` | string | Identificador del equipo: MAC; si no hay, serial; si no, un UUID persistente con prefijo `OFFMAC-`. |
| `employee_full_name` | string | Nombre del cajero con sesión activa al momento del evento (`"Cajero"` si no se encuentra). |
| `cashier_id` | string (número) | ID del cajero activo (`"1"` si no había cajero con sesión). |
| `typ` | string | Igual a `type_code`. |
| `ver` | string | Versión del formato de trama, hoy `"1.0.0"`. |
| `pos_location_id` | string (número) | Punto de venta. Puede no venir si el equipo aún no tiene POS asignado. |

## Respuesta esperada

| Código HTTP | Qué hace el POS |
|-------------|-----------------|
| `200` / `201` | Marca el evento como enviado. |
| `409` | Lo toma como **ya recibido** (duplicado) y lo marca como enviado. |
| Otro `4xx` | Lo deja pendiente y lo reintenta más tarde. |
| `5xx` / timeout (5 s) | Lo deja pendiente y lo reintenta más tarde. |

El cuerpo de la respuesta no se usa; puede ser el mismo de las otras tramas, por ejemplo:

```json
{ "success": true, "data": { "pos_transaction_id": 12345 } }
```

## Reintentos y duplicados

- El POS intenta enviar los pendientes **como máximo una vez por minuto**, de a **20 eventos** por ronda, en orden cronológico.
- Si el backend rechaza un evento, se corta la ronda y se reintenta en la siguiente.
- Puede llegar **el mismo evento dos veces** (por ejemplo, si el backend lo guardó pero la respuesta no llegó). Se recomienda deduplicar por `ime` + `type_code` + `dat` y responder `409` en ese caso.

## Recomendaciones para el backend

1. Aceptar `RC175` y `RC176` en `/pos-transactions` sin exigir `token` ni campos de venta (monto, tarifa, QR).
2. Estas tramas **no son ventas**: no deben sumar en cuadres, cierres ni conteos de transacciones.
3. Guardar al menos: `type_code`, `dat` (convertido a fecha), `ime`, `hw`, `cashier_id`, `pos_location_id` y la fecha de recepción.
4. Útil para reportes: tiempo sin impresora = diferencia entre un `RC175` y el siguiente `RC176` del mismo `ime`.
