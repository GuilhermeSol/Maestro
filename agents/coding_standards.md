# iOS Coding Standards

These standards apply to every file created or modified in this project.
They are the definitive reference for both implementation and review.

---

**Architecture — Separation of Concerns**

The codebase uses the layers from the Code Structure Guide in CLAUDE.md
that apply to this project. Every new file belongs to exactly one
layer. When in doubt about placement, apply the dependency rule first.

_Dependency rule — non-negotiable_
Dependencies point inward. Outer layers may depend on inner layers.
Inner layers must never import outer layers. All cross-layer
communication is through protocols defined in the inner layer.

```
       ┌─────────────────────────────┐
       │      Composition Root       │  ← imports all layers, wires
       └─────────────────────────────┘     concrete instances (direct)
              │              │
           direct          direct
              ↓              ↓
       ┌──────────┐        ┌──────────┐
       │    UI    │        │   Data   │
       └──────────┘        └──────────┘
              ┊                  ┊
        abstraction          abstraction
        (protocol)           (protocol)
              ┊                  ┊
              ↓                  ┊
       ┌─────────────────────┐   ┊
       │     Presentation    │   ┊
       └─────────────────────┘   ┊
              ┊                  ┊
        abstraction              ┊
        (protocol)               ┊
              ┊                  ┊
              ↓                  ↓
       ┌──────────────────────────────┐
       │            Domain            │  ← no external dependencies
       └──────────────────────────────┘

Legend:
  ↓  direct dependency      — imports, names, and constructs the
     concrete type (only Composition Root does this)
  ┊  abstraction dependency — depends only on a protocol's interface,
     never a concrete type (generic constraint, opaque type, or
     existential — see `architecture_rationale.md` for the distinction)

Note: the Composition Root also imports Presentation and Domain
directly (it is "the only module that imports all layers") — those
two direct arrows are omitted above to keep the layout readable.
```

_Dependency graph — text form (authoritative over the diagram above)_

- Composition Root → UI, Data, Presentation, Domain — *direct*. Builds
  every concrete type and wires them together; the only place that's
  allowed.
- UI → Presentation — *abstraction, usage*. A View is generic over a
  ViewModel protocol it owns; never names a concrete ViewModel type.
- Presentation → Domain — *abstraction, usage*. Same shape one layer
  in: the ViewModel is generic over a protocol it owns, never naming a
  concrete Domain type.
- Data → Domain — *abstraction, realization*. Data implements a
  repository protocol Domain declares — provider of the contract, not
  a caller (opposite role from the two edges above).

Does not exist: Data → Presentation (Data routes straight to Domain),
UI → Domain (UI only ever talks to Presentation), and in multi-module
projects, any edge between sibling modules (Composition Root is the
only bridge — see the project's own `ARCHITECTURE.md`).

Default to a generic constraint (`<T: P>` / `some P`) over an
existential (`any P`) for these abstraction edges; reach for `any P`
only where a value must hold genuinely different conforming types at
runtime. Full sourced rationale (Swift Evolution proposals, dispatch
mechanics, usage-vs-realization distinction, modern-architecture
verification): `architecture_rationale.md` — not required reading,
consult only if one of these calls is disputed or needs citing.

_Layer 1 — Domain (innermost)_
The centre of the app. Contains:
- Domain models: plain Swift value types (struct, enum) — no
  persistence annotations, no network types
- Use case protocols and implementations: one protocol per use case,
  one struct per implementation
- Repository protocols: abstract data access interfaces defined here,
  implemented in the Data layer
- Policy contracts: business rules and validation types (e.g. a
  Username type that enforces a max-length rule, a Percentage type
  that rejects values above 100) — pure Swift, self-enforcing,
  impossible to construct in an invalid state

Rules:
- No imports of UIKit, SwiftUI, CoreData, URLSession, or any
  infrastructure framework
- No knowledge of how data is fetched, stored, or displayed
- Must be fully testable with plain unit tests — no simulator, no
  network, no database required
- The rule lives here. The error message shown to the user lives in
  Presentation. Never mix them.

_Layer 2 — Data_
Implements the Domain repository protocols. Contains:
- Network clients (URLSession-backed)
- Persistence stores (CoreData / SwiftData implementations)
- DTOs (raw API response types)
- Mappers: DTO → Domain Model, NSManagedObject → Domain Model

Rules:
- A CoreData NSManagedObject must never leave this layer — map it to a
  domain model at the boundary before returning
- A raw DTO must never leave this layer — map it before returning
- Depends on Domain (to implement its protocols); knows nothing about
  Presentation or UI

_Layer 3 — Presentation_
Transforms domain models into display-ready values. Contains:
- ViewModels: generic over a protocol they own (e.g. `ViewModel<Item:
  ItemProtocol>`), calling use cases through that same generic
  constraint; output display models
- Display models: plain structs with pre-formatted strings, boolean
  flags, and UI-ready values — zero business logic
- Error message mapping: catches domain validation errors and converts
  them to user-facing strings

Rules:
- A domain model must never be passed to a View — always convert to a
  display model first
- ViewModels depend on a generic protocol constraint they own, not on
  Domain's concrete types directly — Composition Root supplies a
  Domain type that conforms
- No UIKit or SwiftUI imports — ViewModels are plain Swift, testable
  without a simulator
- One ViewModel per screen or major UI component

_Layer 4 — UI (outermost)_
Pure rendering. Contains:
- SwiftUI Views
- View-local helpers scoped to a single view (layout constants,
  view-specific formatters)

Rules:
- Views receive display models only — never domain models, never
  CoreData objects
- Zero business logic in a View — if a View is making a decision about
  data, that logic belongs in the ViewModel
- Views do not call use cases directly — all data flow goes through
  the ViewModel
- Every View must be constructable with a hardcoded display model
  (enables Previews and isolated UI tests)

_Composition Root — App target_
The only module that imports all layers. Wires everything together
via dependency injection. Contains factory functions, DI setup, and
the app entry point (`@main`).

Rules:
- The only place where a concrete store, a concrete network client,
  and a ViewModel legitimately appear in the same file
- No business logic — it only creates and connects
- No layer creates its own dependencies; all concrete types are
  constructed here and injected inward

_Deciding where a new file belongs_
Ask in order — stop at the first Yes:

1. Does it import SwiftUI or UIKit? → UI
2. Does it create or inject concrete implementations to wire layers
   together? → Composition Root
3. Does it access or transform data from a network, database, file
   system, or external service? → Data
4. Does it prepare or represent data for display (ViewModels,
   Presenters, display models)? → Presentation
5. None of the above → Domain
   (entities, use cases, repository protocols, policy contracts —
   pure Swift, no dependencies outside this layer)

---

**Language**
- Default to Swift and SwiftUI for all new code
- Use Objective-C or UIKit only when modifying an existing file
  already written in Objective-C or UIKit — do not introduce them
  into new files

---

**Concurrency**

Target Swift 6 strict concurrency. All new code must compile with zero
warnings under complete concurrency checking. Do not target Swift 5.x
behaviour unless `maestro.yaml` specifies a lower language version.

_Actors and isolation_
- Use `actor` for any shared mutable state — no manual locking or
  `DispatchQueue` for state protection
- Mark all types that update UI with `@MainActor` — enforced at compile
  time in Swift 6
- Use `nonisolated` on methods of a `@MainActor` type that are pure
  computation and do not touch actor-isolated state — avoids forcing
  callers to `await` unnecessarily
- Never use `DispatchQueue` in new code — use actors and `async/await`
- Beware actor reentrancy: state can change across any `await` inside an
  actor — re-check state after every suspension point before acting on it

_Structured concurrency_
- Use structured concurrency by default: `async let`, `withTaskGroup`,
  `withThrowingTaskGroup`, or child tasks
- Use `async let` for a fixed set of independent operations that must all
  complete together
- Use `withTaskGroup` / `withThrowingTaskGroup` when the number of
  concurrent tasks is dynamic or data-driven
- Only use unstructured `Task { }` when there is no ambient async context
  (e.g., `viewDidLoad`, a SwiftUI button action, a lifecycle callback)
- Never use `Task.detached` unless the work must explicitly not inherit
  the caller's actor context and priority — justify with a comment

_Task lifecycle_
- Always handle cancellation: check `Task.isCancelled` at the top of
  loops and before expensive work; use `withTaskCancellationHandler` for
  cleanup of external resources
- Never store a `Task` handle without cancelling it — call `.cancel()`
  explicitly on `deinit` or SwiftUI `onDisappear`
- Use SwiftUI's `.task { }` modifier for view-scoped async work — it
  cancels automatically on disappear

_Sendable and data safety_
- All types passed across actor boundaries must conform to `Sendable`
- Mark closure parameters as `@Sendable` when they cross actor or task
  boundaries
- Never use `@unchecked Sendable` without a comment explaining exactly
  why the type is safe (e.g., all mutations are internally synchronised)
- Use the `sending` parameter modifier when a function takes ownership of
  a value to transfer it across a concurrency boundary

_Bridging legacy APIs_
- Wrap completion-handler APIs with `withCheckedContinuation` or
  `withCheckedThrowingContinuation` — never mix completion handlers with
  `async/await` at new call sites
- Use `@preconcurrency` on imports or conformances only to suppress
  warnings from third-party code not yet on Swift 6 — remove as soon as
  the dependency is updated
- Use Combine only when modifying existing Combine code — do not
  introduce it in new files

_Streaming values_
- Use `AsyncStream` or `AsyncThrowingStream` for sequences of values over
  time in new code — these replace Combine publishers
- Prefer `AsyncStream.makeStream()` (Swift 5.9+) over the closure-based
  initialiser for cleaner continuation management

_Hard constraints_
- Do not `await` inside a `defer` block — it will not compile
- Do not call `async` functions from a `@Sendable` closure unless the
  closure is itself `async`

---

**Optionals**
- No force unwraps (`!`) unless absolutely justified
- If used, add a one-line comment explaining why it is safe

---

**Error handling**
- Handle all error states explicitly
- No empty catch blocks — at minimum, log the error

---

**Strings**
- No hardcoded user-facing strings
- Use constants or localisation keys

---

**Data Storage**

_Existing project_
- If the project already uses a persistence system (Core Data, SwiftData,
  Realm, SQLite, UserDefaults for structured data), use that system — do
  not introduce a second persistence layer
- Read the existing stack in full before writing any persistence code:
  understand the managed object model, store configuration, or equivalent
  before touching it

_New storage required_
- If no persistence system exists and one must be created, stop and ask:
  ```
  A data storage layer is needed and none exists in this project.
  1. Core Data — battle-tested, full migration tooling, supports all
     iOS versions (Recommended)
  2. SwiftData — modern Swift-native API, requires iOS 17+, schema
     migration tooling is less mature
  Which should we use?
  ```
  Wait for the user's choice. Do not create anything before it is confirmed.

_Schema change — mandatory migration check_
Any time you modify a type, entity, or model that is persisted to storage
(added, removed, or renamed property; changed type; changed relationship),
stop before writing code and assess:

1. Does this change alter the on-disk schema?
2. If yes — is a migration required?
3. Will an installed version of the app open the store without crashing
   when the new version is installed over it?

Never proceed with a schema change until all three questions are answered.

For Core Data:
- Add a new model version before modifying the existing version — never
  edit the current version in place
- Determine if the change is lightweight-compatible (add optional
  attribute, add entity, rename with mapping model hint)
- If not lightweight, a custom `NSMigrationPolicy` is required — surface
  this to the user before writing any code
- Never remove or rename a persistent attribute without a migration plan

For SwiftData:
- Use `VersionedSchema` and `SchemaMigrationPlan` for any model change
- Define the previous schema as a separate `VersionedSchema` enum case
  before modifying the current model
- Test migration on a seeded store, not just a clean install

_Backward compatibility — non-negotiable_
Before committing any schema change, confirm all of the following:
- Migration runs automatically on first launch — no user action required
- An app upgraded from the previous shipped version opens the migrated
  store without data loss
- A migration failure does not corrupt the store — catch and surface
  migration errors; never silently swallow them or let the app crash
- Test the upgrade path from the last shipped version, not just a
  fresh install

---

**Security**
- When code touches secrets, tokens, storage, network, logging or user
  input, check the rules in `agents/security_standards.md` §2.
- If you flag a security problem, cite its rule ID (`SEC-<AREA>-NN`).

---

**SOLID**
Apply SOLID at all times as defined in CLAUDE.md. Never skip or defer
this — violations must be surfaced and documented.

---

**Access control**
- Default to `private`; widen to `internal` only when an internal
  caller requires it
- If a test requires access to a private symbol, first try to test
  through the public interface or use `@testable import`
- Only widen access for a test as a last resort — if no other path
  exists, notify the user:
  ```
  ⚠️ Widened access on [File:Symbol] from private to internal
     to satisfy [TC-ID] — no other access path found.
  ```

---

**Types**
- Prefer value types (struct, enum) over reference types (class)
  unless reference semantics are explicitly required

---

**Naming**
- Follow Swift API Design Guidelines
- Types: UpperCamelCase — functions and properties: lowerCamelCase
