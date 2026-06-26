<div style="text-align: center;">

# MaviosCrochet Backend API

**A High-Performance Quarkus Web API using Modular Monolith & Clean Architecture**


[![Framework: Quarkus](https://img.shields.io/badge/Quarkus-3.31.1-FF7828?logo=quarkus)](https://quarkus.io/) 
[![Database: PostgreSQL](https://img.shields.io/badge/PostgreSQL-%5E15.0-4169E1?logo=postgresql)](https://www.postgresql.org/) 
[![Database: MongoDB](https://img.shields.io/badge/MongoDB-%5E6.0-47A248?logo=mongodb)](https://www.mongodb.com/) 
[![API: SmallRye OpenAPI](https://img.shields.io/badge/OpenAPI-3.0-green?logo=openapi-initiative)](https://github.com/smallrye/smallrye-open-api)

</div>

> 🌐 **[Versión en español (README_ES.md)](README_ES.md)**

---

## 🚀 Overview

This is the backend web API for MaviosCrochet, built using **Quarkus (the Supersonic Subatomic Java Framework)**. It handles e-commerce business rules, order creations, double-entry inventory, coupon discounts, secure shipping calculations, and digital pattern watermark processing.

The backend is structured as a **Modular Monolith** to keep compilation fast, deployment simple, and modules highly decoupled so they can easily migrate to microservices in the future if required.

---

## 📁 Architecture & Packaging

To maintain a strict separation of concerns, each business domain resides in its own package under `com.mavioscrochet.modules.<name>` and is structured into four distinct layers (Clean / Hexagonal architecture style):

```
backend/src/main/java/com/mavioscrochet/
├─ modules/
│  ├─ sales/               # Sales, cart, and payment bounded context (Example)
│  │  ├─ api/              # API Layer (REST resources, HTTP DTOs, Object Mappers)
│  │  ├─ core/
│  │  │  ├─ application/   # Application Layer (Granular single-responsibility Use Case interactors)
│  │  │  ├─ domain/        # Domain Layer (Aggregate roots, entities, value objects, repo interfaces)
│  │  ├─ infrastructure/   # Infrastructure Layer (JPA repositories, Wompi/PayPal client implementations)
│  ├─ catalog/             # Product catalog & pricing
│  ├─ inventory/           # Stock reservations & counts
│  ├─ production/          # Physical item handcrafted queues
│  ├─ shipping/            # Shipping rates, couriers, and tracking updates
│  ├─ users/               # Customer profiles and authentication
├─ shared/                 # Shared utilities and configurations (Locales, security filters)
```

### Layer Constraints
1. **Domain Layer**: Must be pure Java. It defines business rules (e.g. `Order.java`) and Repository Interfaces. It depends on nothing else.
2. **Application Layer**: Contains Use Cases (e.g. `CreateOrderUseCase.java`). It coordinates the domain objects and repository interfaces to complete a business action.
3. **API & Infrastructure Layers**: Adapters that plug into the core. They handle JSON serialization, CDI bean declarations, database interactions, and network calls.

---

## 🗄️ Database Strategy

MaviosCrochet implements a hybrid database model to leverage the strengths of different storage engines:

- **PostgreSQL**: Stores transactional, highly-structured data that requires strict ACID compliance (Users, Orders, Payments, Catalog Products).
- **MongoDB**: Used for high-throughput, unstructured audit logs, storing raw payment webhook payloads, and carrier updates.

---

## 🛠️ Advanced Architectural Patterns & Algorithms

The backend incorporates high-value patterns and specialized algorithms designed for robustness and performance:

### 1. Application Layer Design (Facade + Use Case Pattern)
To avoid monolithic service bloat (where a service exceeds 1000 lines, such as the original `OrderService.java`), the system isolates business operations into **single-responsibility Use Case interactors**:
- `CreateOrderUseCase`: Coordinates transaction bounds to instantiate orders and reserve production slots.
- `ProcessPaymentUseCase`: Processes state mutations based on gateway payment notifications and webhooks.
- `SettleBalancePayment`: Manages cash adjustments and final transaction updates.
- `OrderQueryService`: Encapsulates authorization checking and projection queries.

The `OrderService.java` is refactored into a **Clean Facade** that acts as an entry gate and delegates to these specific interactors. This guarantees clean code, high unit-test coverage, and strict adherence to the Single Responsibility Principle (SRP).

### 2. Cookie-Based JWT Security & Threat Filtering
- **HttpOnly Cookies**: Prevents client-side access to JWTs, mitigating Cross-Site Scripting (XSS) threats. Uses `SameSite=Lax` to allow secure redirects from Keycloak OAuth brokers (like Google).
- **Token Rotation & Lifetimes**: Refresh tokens (`refreshToken`) are rotated automatically on use and validated against active Keycloak session bounds.
- **Global Interception**: A custom JAX-RS `SecurityFilter` runs prior to authentication to drop requests coming from banned IPs (using Redis-cached SET lookups) or banned users immediately, failing fast without hitting heavy resource endpoints. It also includes a Redis-backed sliding-window rate limiter to throttle excessive requests.

### 3. Heuristic 3D Bin Packing (Shipping Optimization)
To calculate precise shipping quotes prior to billing, the `ShippingManager` implements a **3D Bounding Box / Bin Packing** algorithm:
- Evaluates 6 distinct orientations (permutations) and 3 stacking direction vectors to pack items dynamically.
- Matches packed dimensions against the active inventory database of boxes, adding a 20% volume slack.
- Dynamically falls back to synthetic boxes using a cube-root mathematical calculation when inventory limits are exceeded.

### 4. FIFO Production Capacity Scheduler
- Plans handicraft capacity by breaking down item quantities into separate units.
- Allocates daily production hour budgets chronologically (FIFO queue), automatically skipping weekends unless active.
- Handles multi-day task splits for large orders and prevents scheduler fragmentation by keeping the date cursor fixed until the day's capacity is fully exhausted.
- Auto-generates readable **mnemonic tracking codes** (e.g. `#AM-U-DOR-46E6-1`) based on product initials (excluding common Spanish stop-words), size, color prefix, and order ID.

### 5. Threaded Inbox Correlation & IMAP Gmail Synchronization
- **Weighted Match Threading**: Consolidates asynchronous customer inquiries and IMAP events into single-perspective conversational views. It calculates matching scores based on email (+60), normalized phone (+45), IP address (+30), and name (+15).
- **Transaction-Decoupled IMAP Polling**: `GmailInboundService` connects to Gmail's inbox via IMAP to download recent customer emails. It performs network I/O and parsing outside DB transactions to prevent JTA thread lockouts, initiating small transactional writes only when saving deduplicated messages.

---

## ⚙️ Running Locally (Dev Mode)

Run the backend in hot-reload development mode:

```bash
# from backend directory
./mvnw quarkus:dev
```

- **Web API Endpoint**: http://localhost:8080
- **Quarkus Dev UI**: http://localhost:8080/q/dev/
- **MongoDB Dev Services**: Quarkus automatically provisions a test container for Mongo if docker is running.

---

## 📚 API Documentation (Swagger / OpenAPI)

The API is fully documented using SmallRye OpenAPI (Swagger) schemas. You can access the interactive playground to test requests and responses locally:

**🔗 Swagger UI: [http://localhost:8080/q/swagger-ui/](http://localhost:8080/q/swagger-ui/)**

### OpenAPI Definitions
- Raw JSON schema: `http://localhost:8080/q/openapi?format=json`
- Raw YAML schema: `http://localhost:8080/q/openapi`

---

## 📦 Packaging & Compilation

Build a production-ready Uber-Jar containing all dependencies:

```bash
./mvnw package -Dquarkus.package.jar.type=uber-jar
```
The runner jar will be located under `target/*-runner.jar` and can be run using `java -jar target/*-runner.jar`.

---

## 🧪 Testing

I use JUnit 5 and REST Assured for backend testing. To execute the test suite:

```bash
./mvnw clean test
```
All business modules undergo integration testing using transactional test databases.
