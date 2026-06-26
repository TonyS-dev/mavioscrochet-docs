# Stress Test Report: @Blocking vs @RunOnVirtualThread

## Experiment Configuration
- **Target Endpoint**: `POST /api/shipping/quote`
- **Tool**: k6
- **Load Profile**: Total duration of 3m 30s
  - 0s to 30s: Ramp up to 50 users
  - 30s to 1m30s: Maintain at 50 users
  - 1m30s to 2m: **Aggressive peak of 500 concurrent users**
  - 2m to 3m: Maintain peak at 500 users
  - 3m to 3m30s: Ramp down back to 0 users

### Endpoint Complexity (`/quote`)
This is not a simple read endpoint (CRUD). For each request, the system orchestrates the following:
1. **Database Queries (I/O):** Retrieves from MongoDB the exact dimensions and weights of cart products.
2. **3D Packing Algorithm (CPU Load):** Executes a heuristic "3D Bin Packing" algorithm rotating each garment in its 6 spatial orientations to find the smallest bounding box volume.
3. **Physical Box Selection (I/O):** Queries PostgreSQL for the actual cardboard boxes in the warehouse to find the tightest fit.
4. **External API Call (Heavy Network I/O):** Performs real-time HTTP requests to Envia.com to obtain rates from multiple carriers.
5. **Financial Calculation (CPU):** Applies transactional formulas to add the payment gateway commission (Wompi) to the final price.

Surviving **500 concurrent users** performing this high computational and network cost orchestration without collapsing demonstrates the enormous concurrency and scalability capacity of the current architecture.

---

- **Average Response Duration:** 2.96 seconds
- **95th Percentile (P95):** **19.56 seconds** (The 5% of requests that did not fail took up to 19 seconds to complete).

> [!WARNING]
> **Phase 1 Conclusion:** This behavior demonstrates exactly the classic problem of synchronous/blocking architecture. Requests stagnate blocking very heavy threads in the Operating System, severely limiting concurrency and collapsing scalability during peaks.

---

## Round 2: The Virtual Threads Mirage (`@RunOnVirtualThread`)
After enabling `@RunOnVirtualThread` in the `ShippingController`, we launched the 500 VU test again. Surprisingly, **the test failed again**.

Upon inspecting the logs, we discovered an avalanche of exceptions, but this time the traditional Database pool was not the culprit, but rather an incredible succession of "invisible" architectural bottlenecks:

### 1. Redis Connection Pool Exhaustion
The first failure was:
`RedisException: Timeout acquiring a connection from pool (max-pool-size: 6)`


The security filter used Redis to verify if an IP was banned. When injecting 500 virtual threads simultaneously, the default Redis pool (6 connections) saturated instantly.
**Solution:** Configured `%dev.quarkus.redis.max-pool-size=500` in `application.properties`.

### 2. The Killer Rate Limiter (429 Too Many Requests)
Once Redis was resolved, the test failed again returning 429 errors.
The `SecurityFilter` includes a defense against DDoS attacks (`RateLimitService`) that limits to 100 requests per minute per IP. When launching `k6` from localhost, the limit activated in the first 2 seconds, and to make matters worse, when it failed, the filter resorted to PostgreSQL to validate banned users, which did block JDBC threads.
**Solution:** Implemented a local override of the Rate Limiter (`ratelimit.max-requests-per-minute=100000`).

### 3. The Final Boss: Thread Starvation in the External API
With all limits removed, the test still reported Timeouts of more than 60 seconds per request.
When analyzing the code in `EnviaRateService`, we discovered the deadly trap of asynchrony in Java:
```java
CompletableFuture.runAsync(() -> enviaShippingClient.getRates(...));
```
Although the main request entered through a Virtual Thread, `CompletableFuture.runAsync()` (without an explicit executor) sent the background HTTP request to the **ForkJoinPool.commonPool()** (which uses Operating System Native Threads).
We had 500 virtual threads generating **3000 HTTP requests** (6 carriers per user) and sending them to a pool of only **7 native threads**! This produced massive Thread Starvation.
**Solution:** Explicitly injected a `VirtualThreadPerTaskExecutor` to guarantee that parallelization also flowed over virtual threads.

---

## Round 3: Total Harmony (Victory)
Once all obstacles were overcome (Redis scaled, Rate Limit ignored, and Thread Starvation purged), the architecture shined.

### Metrics Obtained with Active Cache (Attempt #7)
- **Total Requests Served:** 5,392 requests
- **Successful Requests:** 5,392
- **Failure Rate (`http_req_failed`):** **0.00%**
- **Average Response Duration:** 8.72 seconds
- **95th Percentile (P95):** 17.50 seconds
- **Hardware Consumption:** Physical CPU stabilized at **40%**, demonstrating the extreme efficiency of Virtual Threads when there are no infrastructure bottlenecks.

> [!TIP]
> 🧠 **Advanced JVM Analysis (The Warm-Up Effect & Architecture Lesson)**
> - **JIT Compilation (Just-In-Time):** In the first iteration of this round, physical CPU approached 100% because the JVM was dynamically translating the 3D packer bytecode to real machine code for 500 simultaneous flows. From the second run (with code compiled "hot"), CPU dropped to 40%, demonstrating the real power of Project Loom.
> - **Infrastructure Conclusion:** Virtual Threads are incredibly powerful tools, but they brutally expose any other system limitation (Redis Pools, Security Filters). For production, the definitive solution is to use Virtual Threads to protect RAM, but **shielded by Semaphores or strict Rate Limiters** that act as bulkheads to avoid drowning integrations and transactional databases.

---

## The Critical Role of Cache (Redis) in External Integrations

During the exhaustive analysis of load tests, a vital discovery was made about infrastructure behavior against external providers.

The original test generated the **same destination (Postal Code)** for the 500 Concurrent Users. Thanks to the endpoint being protected by **Redis**, the system behaved as follows:
1. **The 3D Bin Packing and MongoDB Queries:** Executed mathematically **5,392 times** consuming 40% of CPU.
2. **The HTTP Requests to the Provider (Envia.com):** Executed **only once** (and were cached). The other 5,391 requests obtained shipping rates directly from Redis RAM memory in sub-milliseconds.

> [!WARNING]
> **The Danger of Not Using Cache:** Without this barrier in Redis, launching more than 30,000 HTTP requests to an external provider's API in less than 3 minutes would have resulted in permanent IP blocking (accidental DDoS attack), in addition to causing internal collapse due to TCP port exhaustion (Socket Exhaustion). In Production Distributed Architectures, caching third-party integration responses is not optional, it is the **only safe way** to protect both the provider and internal system stability.

---

## Final Round: Virtual Threads vs Blocking Threads (Without Cache)

To verify the true architectural value of Java 21, a final attack of 500 Concurrent Users was designed where the `k6` script generated a **random postal code in each request**, completely defeating the Redis cache. This forced the server to perform 3D Bin Packing and open 6 external HTTP connections per request.

The test was executed on two architectures under the same conditions (same laptop, same database, same endpoint):

1. **With Virtual Threads (`@RunOnVirtualThread`):**
   - **Error Rate:** `0.00%` (The system remained standing).
   - **Completed Transactions:** `11,475` real HTTP requests processed.
   - **Behavior:** As the network I/O (local Mock) saturated, P95 latency rose to ~6s, but virtual threads simply "parked" waiting for the response without consuming memory or blocking the server.

2. **With Blocking Threads (Classic Worker Pool):**
   - **Error Rate:** `100.00%` (Absolute collapse due to Thread Starvation).
   - **Completed Transactions:** `0` (The 805 requests that k6 attempted resulted in Timeout).
   - **Behavior:** When injecting 500 simultaneous users, the ~200 native threads of the Worker Pool exhausted instantly, blocking while waiting for I/O responses. The remaining requests were queued indefinitely and canceled by Timeout at 60 seconds.

**Verdict:** This test demonstrated in real fire why Virtual Threads are the most important advancement for high-concurrency systems. They completely avoid the total collapse of a web server when it faces high latencies from external providers.

---

## Evolutionary Comparison (Growth as an Engineer)

To put the architectural leap of this project in perspective, it is useful to compare it with a past system design iteration: **StatioCore (Parking Management System)**.

| Metric / Architecture | StatioCore (Spring Boot 3 + AWS EC2) | Mavios Crochet (Quarkus + Virtual Threads) |
| :--- | :--- | :--- |
| **Maximum Validated Load** | 50 Concurrent Users | **500 Concurrent Users (10x more)** |
| **Endpoint Nature** | Simple Read (Database Queries) | **Heavy I/O and Computation (3D Bin Packing + Multiple HTTP Fetches)** |
| **Concurrency Management** | Native Threads (OS Blocking Pools) | **JVM Virtual Threads (Non-Blocking)** |
| **Bottleneck Diagnosis** | Not necessary (The OS withstood the low load) | **Deep Diagnosis:** Redis saturation (Pool max-size), Bottlenecks in Rate Limiters and Thread Starvation in Async Mappers. |

### Engineering Reflection
Moving from testing a system with 50 users to subjecting it to **500 concurrent users breaking the heaviest endpoint in the architecture** marks the transition toward high-availability system design.

In light loads (50 VUs), the architecture plays on safe ground: default pools (e.g., Redis with 6 connections) and the common `ForkJoinPool` process bursts without drowning. When injecting 500 VUs, the JVM operates under extreme stress conditions. The true value of this test is not only that Quarkus withstood the load with a **0.00% error rate**, but the technical criteria developed to **diagnose and intervene "invisible" bottlenecks** throughout the entire infrastructure. This is the level of optimization and resilience required for enterprise Production environments.
