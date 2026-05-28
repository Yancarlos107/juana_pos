# Plantilla de Ticket de Recarga (Impresión Térmica)

Esta plantilla se utilizará para el diseño del comprobante físico (ticket) generado tras una recarga exitosa, cumpliendo con la **Tarea 4.3** del plan de trabajo.

## Diseño Base (ESC/POS 58mm / 80mm)

```text
================================
       Juana RED RECARGA       
       [Nombre de Sucursal]     
================================
Fecha: [DD/MM/YYYY HH:MM:SS]
Transacción: #[ID de Recarga]
Cajero: [Nombre del Usuario]
--------------------------------
      DETALLE DE RECARGA      
--------------------------------
Tarjeta / Perfil: [Card ID]
Método de Pago: [Efectivo/Otro]

MONTO RECARGADO:      $ XXXX.XX
--------------------------------
¡Gracias por usar Juana!
Conserve este recibo para
cualquier reclamo o soporte.
================================
```

## Mapeo de Variables (Integración API)

* **[Nombre de Sucursal]:** Se obtiene del `branch_id` (o nombre de la sucursal mapeado) proveniente de `/user` o mantenido en el estado global.
* **[Fecha]:** Fecha y hora de transacción obtenida del sistema (Flutter) o `created_at` del POST `/recharge-card`.
* **[ID de Recarga]:** El campo `id` devuelto al registrar exitosamente la recarga (`POST /recharge-card`).
* **[Nombre del Usuario]:** El nombre del operador logueado, obtenido del endpoint `GET /user`.
* **[Card ID]:** El ID de la tarjeta o perfil ingresado en el formulario (mismo enviado en `card_id`).
* **[Método de Pago]:** Nombre del método de pago mapeado de `payment_method_id` enviado.
* **[MONTO RECARGADO]:** El valor de `amount` procesado y guardado.

> **Nota para el servicio de impresión:**
> Este ticket se enviará al paquete de Flutter seleccionado (ej. `esc_pos_utils` o `print_pos`) componiendo las líneas de texto anteriores y aplicando estilos de alineación central y bordes según soporte la impresora térmica conectada.