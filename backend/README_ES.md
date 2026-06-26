<div style="text-align: center;">

# MaviosCrochet Backend API

**API Web Quarkus de Alto Rendimiento usando Monolito Modular y Arquitectura Limpia**


[![Framework: Quarkus](https://img.shields.io/badge/Quarkus-3.31.1-FF7828?logo=quarkus)](https://quarkus.io/) 
[![Database: PostgreSQL](https://img.shields.io/badge/PostgreSQL-%5E15.0-4169E1?logo=postgresql)](https://www.postgresql.org/) 
[![Database: MongoDB](https://img.shields.io/badge/MongoDB-%5E6.0-47A248?logo=mongodb)](https://www.mongodb.com/) 
[![API: SmallRye OpenAPI](https://img.shields.io/badge/OpenAPI-3.0-green?logo=openapi-initiative)](https://github.com/smallrye/smallrye-open-api)

</div>

> 🌐 **[English version (README.md)](README.md)**

---

## 🚀 Descripción General

Este es el API web backend de MaviosCrochet, construido usando **Quarkus (el Framework Java Supersónico y Subatómico)**. Maneja las reglas de negocio del e-commerce, creación de órdenes, inventario de doble entrada, descuentos con cupones, cálculos seguros de envío y procesamiento de marcas de agua en patrones digitales.

El backend está estructurado como un **Monolito Modular** para mantener la compilación rápida, el despliegue simple y los módulos altamente desacoplados, permitiendo que puedan migrar fácilmente a microservicios en el futuro si es necesario.

---

## 📁 Arquitectura y Empaquetado

Para mantener una estricta separación de responsabilidades, cada dominio de negocio reside en su propio paquete bajo `com.mavioscrochet.modules.<nombre>` y está estructurado en cuatro capas distintas (estilo Arquitectura Limpia / Hexagonal):

```
backend/src/main/java/com/mavioscrochet/
├─ modules/
│  ├─ sales/               # Contexto acotado de ventas, carrito y pagos (Ejemplo)
│  │  ├─ api/              # Capa API (Recursos REST, DTOs HTTP, Object Mappers)
│  │  ├─ core/
│  │  │  ├─ application/   # Capa de Aplicación (Interactores de casos de uso con responsabilidad única)
│  │  │  ├─ domain/        # Capa de Dominio (Raíces de agregado, entidades, value objects, interfaces de repo)
│  │  ├─ infrastructure/   # Capa de Infraestructura (Repositorios JPA, implementaciones de clientes Wompi/PayPal)
│  ├─ catalog/             # Catálogo de productos y precios
│  ├─ inventory/           # Reservas de stock y conteos
│  ├─ production/          # Colas de producción artesanal
│  ├─ shipping/            # Tarifas de envío, transportistas y actualizaciones de tracking
│  ├─ users/               # Perfiles de clientes y autenticación
├─ shared/                 # Utilidades compartidas y configuraciones (Locales, filtros de seguridad)
```

### Restricciones por Capa
1. **Capa de Dominio**: Debe ser Java puro. Define las reglas de negocio (ej. `Order.java`) e Interfaces de Repositorio. No depende de nada más.
2. **Capa de Aplicación**: Contiene los Casos de Uso (ej. `CreateOrderUseCase.java`). Coordina los objetos de dominio y las interfaces de repositorio para completar una acción de negocio.
3. **Capas de API e Infraestructura**: Adaptadores que se conectan al core. Manejan la serialización JSON, declaraciones de beans CDI, interacciones con la base de datos y llamadas de red.

---

## 🗄️ Estrategia de Base de Datos

MaviosCrochet implementa un modelo de base de datos híbrido para aprovechar las fortalezas de diferentes motores de almacenamiento:

- **PostgreSQL**: Almacena datos transaccionales y altamente estructurados que requieren estricto cumplimiento ACID (Usuarios, Órdenes, Pagos, Productos del Catálogo).
- **MongoDB**: Usado para logs de auditoría de alto rendimiento y datos no estructurados, almacenando payloads crudos de webhooks de pago y actualizaciones de transportistas.

---

## 🛠️ Patrones Arquitectónicos Avanzados y Algoritmos

El backend incorpora patrones de alto valor y algoritmos especializados diseñados para robustez y rendimiento:

### 1. Diseño de la Capa de Aplicación (Patrón Fachada + Caso de Uso)
Para evitar el inflado de servicios monolíticos (donde un servicio supera las 1000 líneas, como el `OrderService.java` original), el sistema aísla las operaciones de negocio en **interactores de Casos de Uso de responsabilidad única**:
- `CreateOrderUseCase`: Coordina los límites transaccionales para instanciar órdenes y reservar espacios de producción.
- `ProcessPaymentUseCase`: Procesa mutaciones de estado basadas en notificaciones y webhooks de las pasarelas de pago.
- `SettleBalancePayment`: Gestiona ajustes de efectivo y actualizaciones finales de transacciones.
- `OrderQueryService`: Encapsula la verificación de autorización y consultas de proyección.

El `OrderService.java` está refactorizado en una **Fachada Limpia** que actúa como puerta de entrada y delega a estos interactores específicos. Esto garantiza código limpio, alta cobertura de pruebas unitarias y adherencia estricta al Principio de Responsabilidad Única (SRP).

### 2. Seguridad JWT Basada en Cookies y Filtro de Amenazas
- **Cookies HttpOnly**: Previene el acceso del lado del cliente a los JWTs, mitigando amenazas de Cross-Site Scripting (XSS). Usa `SameSite=Lax` para permitir redirecciones seguras desde brokers OAuth de Keycloak (como Google).
- **Rotación y Tiempo de Vida de Tokens**: Los tokens de refresco (`refreshToken`) se rotan automáticamente al usarse y se validan contra los límites de sesión activos de Keycloak.
- **Intercepción Global**: Un `SecurityFilter` JAX-RS personalizado se ejecuta antes de la autenticación para descartar peticiones provenientes de IPs baneadas (usando lookups de SET cacheados en Redis) o usuarios baneados inmediatamente, fallando rápido sin impactar endpoints de recursos pesados. También incluye un rate limiter basado en ventana deslizante respaldado por Redis para limitar peticiones excesivas.

### 3. Empaque en 3D Heurístico (Optimización de Envíos)
Para calcular cotizaciones de envío precisas antes de la facturación, el `ShippingManager` implementa un algoritmo de **Caja Delimitadora 3D / Bin Packing**:
- Evalúa 6 orientaciones distintas (permutaciones) y 3 vectores de dirección de apilamiento para empaquetar artículos dinámicamente.
- Compara las dimensiones empacadas contra la base de datos de inventario activo de cajas, añadiendo una holgura de volumen del 20%.
- Escapa dinámicamente a cajas sintéticas usando un cálculo matemático de raíz cúbica cuando se exceden los límites del inventario.

### 4. Planificador de Capacidad de Producción FIFO
- Planifica la capacidad artesanal desglosando las cantidades de artículos en unidades separadas.
- Asigna presupuestos de horas de producción diarias cronológicamente (cola FIFO), saltando fines de semana automáticamente a menos que estén activos.
- Maneja divisiones de tareas de múltiples días para órdenes grandes y previene la fragmentación del planificador manteniendo el cursor de fecha fijo hasta que la capacidad del día se agote completamente.
- Autogenera **códigos de seguimiento mnemotécnicos** legibles (ej. `#AM-U-DOR-46E6-1`) basados en las iniciales del producto (excluyendo stop-words comunes en español), talla, prefijo de color y el ID de la orden.

### 5. Correlación de Bandeja de Entrada con Hilos y Sincronización IMAP de Gmail
- **Coincidencia Ponderada de Hilos**: Consolida consultas asíncronas de clientes y eventos IMAP en vistas conversacionales de una sola perspectiva. Calcula puntajes de coincidencia basados en correo electrónico (+60), teléfono normalizado (+45), dirección IP (+30) y nombre (+15).
- **Polling IMAP Desacoplado de Transacciones**: `GmailInboundService` se conecta a la bandeja de Gmail vía IMAP para descargar correos recientes de clientes. Realiza operaciones de red I/O y parseo fuera de transacciones DB para prevenir bloqueos de hilos JTA, iniciando pequeñas escrituras transaccionales solo al guardar mensajes deduplicados.

---

## ⚙️ Ejecución Local (Modo Desarrollo)

Ejecuta el backend en modo desarrollo con hot-reload:

```bash
# desde el directorio backend
./mvnw quarkus:dev
```

- **Endpoint del API Web**: http://localhost:8080
- **Quarkus Dev UI**: http://localhost:8080/q/dev/
- **MongoDB Dev Services**: Quarkus provisiona automáticamente un contenedor de prueba para Mongo si Docker está corriendo.

---

## 📚 Documentación del API (Swagger / OpenAPI)

El API está completamente documentada usando esquemas SmallRye OpenAPI (Swagger). Puedes acceder al playground interactivo para probar peticiones y respuestas localmente:

**🔗 Swagger UI: [http://localhost:8080/q/swagger-ui/](http://localhost:8080/q/swagger-ui/)**

### Definiciones OpenAPI
- Esquema JSON crudo: `http://localhost:8080/q/openapi?format=json`
- Esquema YAML crudo: `http://localhost:8080/q/openapi`

---

## 📦 Empaquetado y Compilación

Construye un Uber-Jar listo para producción con todas las dependencias:

```bash
./mvnw package -Dquarkus.package.jar.type=uber-jar
```
El jar ejecutable estará ubicado en `target/*-runner.jar` y puede ejecutarse usando `java -jar target/*-runner.jar`.

---

## 🧪 Testing

Uso JUnit 5 y REST Assured para las pruebas del backend. Para ejecutar la suite de pruebas:

```bash
./mvnw clean test
```
Todos los módulos de negocio pasan por pruebas de integración usando bases de datos transaccionales de prueba.
