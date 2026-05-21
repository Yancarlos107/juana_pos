# Valliu Sistema POS (Red de Recarga) - Documentación Maestra

**⚠️ AVISO PARA AGENTES DE IA ⚠️**
Este `README.md` es la **ÚNICA FUENTE DE VERDAD** para las reglas de negocio, el flujo operativo y el estado del proyecto. Debes basar todas tus implementaciones en este documento. 

---

## 1. Estado Actual del Proyecto (v2.13)
El proyecto actualmente cuenta con las siguientes funcionalidades ya desarrolladas:
- **UI/UX**: `LoginScreen` y `DashboardScreen` modernizados (temas claros, saldo en el header).
- **Lógica Local**: Manejo de saldo con `SharedPreferences`, extracción desde JSON (`data.branch.account.cards[0].balance`), bloqueo de venta si el saldo es insuficiente.
- **Hardware**: Integración nativa de Impresión Térmica (ESC/POS vía USB) y ajuste horario a UTC-5. Generación nativa de códigos QR.
- **Documentación Técnica Adicional**: 
  - `red-recarga-consola.md`: Documentación de los endpoints API y comportamiento de la consola web.
  - `ticket-template.md`: Diseño base para la tirilla térmica.
  - `ESTADO_PROYECTO.md`: Historial detallado de cambios.

---

## 2. Flujo Operativo y de Trabajo (Roadmap de Desarrollo)

Este es el flujo funcional completo, integrando operaciones en línea y fuera de línea (offline):

### 1. Inicialización
1.1. Sucede cuando inicia la app (se descarga la data) y cada vez que se realiza un login en línea exitoso.
1.2. Descarga la data desde el endpoint y la almacena localmente para uso offline.
**Datos a descargar y sincronizar:**
- Rutas
- Tarifas (Productos)
- Usuarios vs Hash de Claves (para autenticación offline)
- Data de caja vs Red de recarga

### 2. Login (Online / Offline)
2.1. **Online:** Autenticación directa contra la API de Valliu y descarga de inicialización (Paso 1).
2.2. **Sin sesión:** Si no hay sesión de caja abierta, el sistema procede a abrir una nueva.
2.3. **Sesión del mismo día:** Si ya existe una sesión de caja abierta correspondiente al mismo día, avisa al usuario e inicia el módulo de ventas sobre esa misma sesión.
2.4. **Sesión de otro día (atrasada):** Si hay una sesión de caja abierta de un día anterior, el sistema avisa al usuario, la cierra automáticamente marcándola como "tardía", e inicia ventas abriendo una nueva sesión.

### 3. Apertura de Caja
Flujo para registrar la apertura de caja y el saldo o fondo base antes de comenzar a operar.

### 4. Venta de Productos x Tarifas
4.1. Se presenta la lista de productos/tarifas disponibles y sus valores.
4.2. **Campo PMR (Personas con Movilidad Reducida):** (0,1). Si el producto es PMR, se muestra el símbolo de discapacitado en la interfaz.

### 5. Revisión de Ventas
5.1. Reporte interno local con todos los campos y valores. Muestra el total de ventas acumulado hasta el momento de la revisión.

### 6. Cierre de Caja
6.1. Pantalla resumen que muestra: Total de ventas desglosado por cada producto, su valor total y la suma global.
6.2. **Impresión de la tirilla de cierre de caja:**
   - Subtotal por cada producto y el total general.
   - **En Línea:** Crea un código QR con la estructura JSON del cierre y lo transmite a Valliu.
   - **Offline:** Crea un código QR principal (JSON del cierre) y códigos QR adicionales manuales (estructura tag-and-value, compresión, encriptación, base64) para subida manual.
6.3. Las transacciones y cierres quedan pendientes localmente y se transmiten automáticamente cuando el servicio de monitoreo detecta conexión (marcado como "cerrado offline").

### 7. Apertura PMR
7.1. Se envía un comando a un endpoint local o de hardware para abrir la puerta. Esta acción se registra internamente como una transacción "manual".

### 8. Logout
8.1. Al intentar cerrar sesión, el sistema pregunta al operador si desea realizar el "Cierre de Caja". Luego, invalida la sesión activa.

### 9. Servicio Interno de Monitoreo
Servicio en segundo plano que refleja el estado del sistema mediante íconos (Verde/Rojo) en el header:
- **Impresora:** Conectividad USB/Bluetooth.
- **Conexión a Internet:** Estado de red.
- **PMR:** Conectividad y respuesta del endpoint de la puerta.
- **Transacciones Pendientes:** Indicador con la cantidad de transacciones por transmitir.

### 10. Recepción y Transmisión de Transacción Apertura Física PMR
Gestión asíncrona de los eventos de apertura física para consolidarlos con las transacciones de caja.
