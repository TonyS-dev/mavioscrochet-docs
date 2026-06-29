# Reporte de Pruebas de Estrés: @Blocking vs @RunOnVirtualThread

## Configuración del Experimento
- **Endpoint Objetivo**: `POST /api/shipping/quote`
- **Herramienta**: k6
- **Perfil de Carga**: Duración total de 3m 30s
  - 0s a 30s: Rampa subiendo a 50 usuarios
  - 30s a 1m30s: Mantenimiento en 50 usuarios
  - 1m30s a 2m: **Pico agresivo de 500 usuarios concurrentes**
  - 2m a 3m: Mantenimiento del pico en 500 usuarios
  - 3m a 3m30s: Descenso de vuelta a 0 usuarios

### Complejidad del Endpoint (`/quote`)
Este no es un endpoint de lectura simple (CRUD). Por cada petición, el sistema orquesta lo siguiente:
1. **Consultas a Base de Datos (I/O):** Recupera desde MongoDB las dimensiones y pesos exactos de los productos del carrito.
2. **Algoritmo de Empaquetado 3D (Carga de CPU):** Ejecuta un algoritmo heurístico de "3D Bin Packing" rotando cada prenda en sus 6 orientaciones espaciales para encontrar el volumen de caja delimitadora más pequeño.
3. **Selección de Caja Física (I/O):** Consulta en PostgreSQL las cajas de cartón reales del almacén para encontrar la más ajustada.
4. **Llamada a API Externa (Heavy Network I/O):** Realiza peticiones HTTP en tiempo real a Envia.com para obtener tarifas de múltiples transportadoras.
5. **Cálculo Financiero (CPU):** Aplica fórmulas transaccionales para sumar la comisión de la pasarela de pagos (Wompi) al precio final.

Sobrevivir a **500 usuarios concurrentes** haciendo esta orquestación de alto costo computacional y de red sin colapsar, demuestra la enorme capacidad de concurrencia y escalabilidad de la arquitectura actual.

---

- **Duración Promedio de Respuesta:** 2.96 segundos
- **Percentil 95 (P95):** **19.56 segundos** (El 5% de las peticiones que no fallaron tardaron hasta 19 segundos en completarse).

> [!WARNING]
> **Conclusión de la Fase 1:** Este comportamiento demuestra exactamente el problema clásico de la arquitectura síncrona/bloqueante. Las peticiones se estancan bloqueando hilos muy pesados en el Sistema Operativo, limitando severamente la concurrencia y desplomando la escalabilidad ante picos.

---

## Ronda 2: El Espejismo de los Hilos Virtuales (`@RunOnVirtualThread`)
Después de habilitar `@RunOnVirtualThread` en el `ShippingController`, volvimos a lanzar la prueba de 500 VUs. Sorprendentemente, **la prueba volvió a fallar**. 

Al inspeccionar los logs, descubrimos una avalancha de excepciones, pero esta vez no era el pool de la Base de Datos tradicional el culpable, sino una sucesión increíble de cuellos de botella "invisibles" de arquitectura:

### 1. Agotamiento del Pool de Conexiones de Redis
La primera falla fue:
`RedisException: Timeout acquiring a connection from pool (max-pool-size: 6)`


El filtro de seguridad usaba Redis para verificar si una IP estaba baneada. Al inyectar 500 hilos virtuales simultáneos, el pool por defecto de Redis (6 conexiones) se saturó instantáneamente.
**Solución:** Se configuró `%dev.quarkus.redis.max-pool-size=500` en `application.properties`.

### 2. El Rate Limiter Asesino (429 Too Many Requests)
Una vez resuelto Redis, la prueba falló de nuevo devolviendo errores 429.
El `SecurityFilter` incluye una defensa contra ataques DDoS (`RateLimitService`) que limita a 100 peticiones por minuto por IP. Al lanzar `k6` desde localhost, el límite se activó en los primeros 2 segundos, y para colmo, cuando fallaba, el filtro recurría a PostgreSQL para validar usuarios baneados, lo cual sí bloqueaba hilos de JDBC.
**Solución:** Se implementó una anulación local del Rate Limiter (`ratelimit.max-requests-per-minute=100000`).

### 3. El Jefe Final: Thread Starvation en la API Externa
Con todos los límites eliminados, el test seguía reportando Timeouts de más de 60 segundos por petición.
Al analizar el código en `EnviaRateService`, descubrimos la trampa mortal de la asincronía en Java:
```java
CompletableFuture.runAsync(() -> enviaShippingClient.getRates(...));
```
Aunque la petición principal entraba por un Hilo Virtual, `CompletableFuture.runAsync()` (sin un ejecutor explícito) enviaba la petición HTTP de fondo al **ForkJoinPool.commonPool()** (que usa Hilos Nativos del sistema operativo).
¡Teníamos 500 hilos virtuales generando **3000 peticiones HTTP** (6 transportadoras por usuario) y enviándolas a un pool de apenas **7 hilos nativos**! Esto produjo una inanición de hilos (Thread Starvation) masiva.
**Solución:** Se inyectó explícitamente un `VirtualThreadPerTaskExecutor` para garantizar que la paralelización también fluyera sobre hilos virtuales.

---

## Ronda 3: Armonía Total (Victoria)
Una vez superados todos los obstáculos (Redis escalado, Rate Limit ignorado, y Thread Starvation purgado), la arquitectura brilló.

### Métricas Obtenidas con Caché Activa (Intento #7)
- **Peticiones Atendidas Totales:** 5,392 peticiones
- **Peticiones Exitosas:** 5,392
- **Tasa de Fallos (`http_req_failed`):** **0.00%**
- **Duración Promedio de Respuesta:** 8.72 segundos
- **Percentil 95 (P95):** 17.50 segundos
- **Consumo de Hardware:** La CPU física se estabilizó en un **40%**, demostrando la eficiencia extrema de los Hilos Virtuales cuando no hay embudos de infraestructura.

> [!TIP]
> 🧠 **Análisis Avanzado de la JVM (El Efecto Warm-Up & Lección de Arquitectura)**
> - **Compilación JIT (Just-In-Time):** En la primera iteración de esta ronda, la CPU física rozó el 100% debido a que la JVM estaba traduciendo dinámicamente el bytecode del empaquetador 3D a código de máquina real para 500 flujos simultáneos. A partir de la segunda corrida (con el código compilado "en caliente"), la CPU cayó al 40%, demostrando el poder real de Project Loom.
> - **Conclusión de Infraestructura:** Los Hilos Virtuales son herramientas increíblemente poderosas, pero exponen brutalmente cualquier otra limitación del sistema (Pools de Redis, Filtros de Seguridad). Para producción, la solución definitiva es usar Hilos Virtuales para proteger la RAM, pero **blindados por Semáforos o Rate Limiters estrictos** que actúen como mamparos (*Bulkheads*) para evitar ahogar las integraciones y las bases de datos transaccionales.

---

## El Papel Crítico de la Caché (Redis) en Integraciones Externas

Durante el análisis exhaustivo de las pruebas de carga, se hizo un descubrimiento vital sobre el comportamiento de la infraestructura frente a proveedores externos. 

El test original generaba el **mismo destino (Código Postal)** para los 500 Usuarios Concurrentes. Gracias a que el endpoint estaba protegido por **Redis**, el sistema se comportó de la siguiente manera:
1. **El Bin Packing 3D y las Consultas a MongoDB:** Se ejecutaron matemáticamente **5,392 veces** consumiendo el 40% de la CPU.
2. **Las Peticiones HTTP al Proveedor (Envia.com):** Se ejecutaron **1 sola vez** (y se cachearon). Las otras 5,391 peticiones obtuvieron las tarifas de envío directamente desde la memoria RAM de Redis en sub-milisegundos.

> [!WARNING]
> **El Peligro de no usar Caché:** Sin esta barrera en Redis, lanzar más de 30,000 peticiones HTTP a la API de un proveedor externo en menos de 3 minutos habría resultado en un bloqueo permanente de IP (Ataque DDoS accidental), además de provocar un colapso interno por agotamiento de puertos TCP (Socket Exhaustion). En Arquitecturas Distribuidas de Producción, cachear las respuestas de integraciones de terceros no es opcional, es la **única forma segura** de proteger tanto al proveedor como a la estabilidad interna del sistema.

---

## Ronda 4: Chaos Engineering & Anti-Fragilidad (El Patrón Bulkhead)

Para probar la resiliencia de la arquitectura bajo condiciones extremas de falla, degradamos intencionalmente el mock de la API externa de Envía, forzando un severo **retraso de 3 segundos por petición**.

Cuando una integración de terceros tarda tanto en responder, las arquitecturas tradicionales sufren una falla en cascada (el backend se cuelga, la RAM se llena, y los usuarios ven errores HTTP 500). Sin embargo, nuestra combinación de `@Bulkhead(value = 50, waitingTaskQueue = 100)` y `@Fallback` realizó una maniobra de control de daños perfecta:

- Los primeros 50 usuarios concurrentes entraron al sistema y esperaron los 3 segundos para las tarifas reales.
- Los siguientes 100 usuarios se encolaron en la cola de tareas de espera.
- **Los 350 usuarios restantes fueron rechazados instantáneamente (rebotaron en el límite del Bulkhead).**

En lugar de colapsar o cortar las conexiones, Quarkus atrapó la `BulkheadException` y ruteó instantáneamente el tráfico excedente al método de contingencia `@Fallback`, entregando una tarifa plana de emergencia preconfigurada en **~5.4 milisegundos**.

**Resultado:** De las 40,720 peticiones inyectadas en 3 minutos, fallaron el **0.00%**. El sistema garantizó que el 90% de los usuarios desbordados recibieran una tarifa de envío de respaldo instantánea, permitiéndoles terminar su compra de inmediato. El sistema protegió con éxito al backend del agotamiento de memoria y preservó las cuotas de la API externa.

---

## Ronda Final: Virtual Threads vs Blocking Threads (Sin Caché)

Para comprobar el verdadero valor arquitectónico de Java 21, se diseñó un ataque final de 500 Usuarios Concurrentes donde el script de `k6` generaba un **código postal aleatorio en cada petición**, derrotando por completo la caché de Redis. Esto obligó al servidor a realizar el Bin Packing 3D y abrir 6 conexiones HTTP externas por cada solicitud.

El test se ejecutó en dos arquitecturas bajo las mismas condiciones (misma laptop, misma base de datos, mismo endpoint):

1. **Con Virtual Threads (`@RunOnVirtualThread`):**
   - **Tasa de Errores:** `0.00%` (El sistema se mantuvo en pie).
   - **Transacciones Completadas:** `11,475` peticiones HTTP reales procesadas.
   - **Comportamiento:** Como la red I/O (Mock local) se saturó, la latencia P95 subió a ~6s, pero los hilos virtuales simplemente se "estacionaron" esperando la respuesta sin consumir memoria ni bloquear el servidor.

2. **Con Blocking Threads (Worker Pool Clásico):**
   - **Tasa de Errores:** `100.00%` (Colapso absoluto por Thread Starvation).
   - **Transacciones Completadas:** `0` (Las 805 peticiones que k6 intentó realizar resultaron en Timeout).
   - **Comportamiento:** Al inyectar 500 usuarios simultáneos, los ~200 hilos nativos del Worker Pool se agotaron instantáneamente, bloqueándose a la espera de respuestas I/O. Las peticiones restantes quedaron encoladas indefinidamente y fueron canceladas por Timeout a los 60 segundos. 

**Veredicto:** Este test demostró en fuego real por qué los Hilos Virtuales son el avance más importante para sistemas de alta concurrencia. Evitan por completo el colapso total de un servidor web cuando este se enfrenta a latencias altas provenientes de proveedores externos.

---

## Comparativa Evolutiva (Crecimiento como Ingeniero)

Para poner en perspectiva el salto arquitectónico de este proyecto, es útil compararlo con una iteración pasada de diseño de sistemas: **StatioCore (Sistema de Gestión de Parqueos)**.

| Métrica / Arquitectura | StatioCore (Spring Boot 3 + AWS EC2) | Mavios Crochet (Quarkus + Virtual Threads) |
| :--- | :--- | :--- |
| **Carga Máxima Validada** | 50 Usuarios Concurrentes | **500 Usuarios Concurrentes (10x más)** |
| **Naturaleza del Endpoint** | Lectura Simple (Queries a Base de Datos) | **Heavy I/O y Computación (Bin Packing 3D + Fetches HTTP Múltiples)** |
| **Gestión de Concurrencia** | Hilos Nativos (Pools Bloqueantes del SO) | **Hilos Virtuales de la JVM (Non-Blocking)** |
| **Diagnóstico de Embudos** | No fue necesario (El SO aguantó la carga baja) | **Diagnóstico profundo:** Saturación de Redis (Pool max-size), Cuellos de botella en Rate Limiters y Thread Starvation en Mappers Asíncronos. |

### Reflexión de Ingeniería
Pasar de probar un sistema con 50 usuarios a someterlo a **500 usuarios concurrentes rompiendo el endpoint más pesado de la arquitectura** marca la transición hacia el diseño de sistemas de alta disponibilidad.

En cargas ligeras (50 VUs), la arquitectura juega en terreno seguro: los pools por defecto (ej. Redis con 6 conexiones) y el `ForkJoinPool` común procesan las ráfagas sin ahogarse. Al inyectar 500 VUs, la JVM opera bajo condiciones extremas de estrés. El verdadero valor de este test no es solo que Quarkus haya aguantado la carga con un **0.00% de errores**, sino el criterio técnico desarrollado para **diagnosticar e intervenir los cuellos de botella "invisibles"** a través de toda la infraestructura. Este es el nivel de optimización y resiliencia requerido para entornos empresariales de Producción.
