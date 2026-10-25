# Architecture Rationale — Dependency Graph

Sourced technical justification for the dependency-graph rules in
`coding_standards.md`. **Not required reading for every ticket** —
consult this only when a DIP/SOLID call is disputed, a design decision
needs citations, or you're deciding between a generic constraint and
an existential for a new abstraction boundary.

---

## Direct vs. abstraction dependency

Only the Composition Root has *direct* dependencies — it is the one
place that names and constructs a concrete type (`TodoListViewModel()`,
`LocalRepository()`, etc.). Every other cross-layer edge (UI→Presentation,
Presentation→Domain, Data→Domain) is an *abstraction* dependency: the
depending layer's source code references only a protocol's interface,
never a concrete type from the layer below.

This holds regardless of whether the protocol dependency is expressed
as a generic constraint (`<T: P>`), an opaque type (`some P`), or an
existential (`any P`) — all three keep the depending layer's source
code coupled only to the protocol, never to a concrete conformer.
[SE-0335](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md)
frames `any` as marking one particular *way* of depending on a
protocol (existential), not as introducing a concrete dependency —
confirming both remain abstraction-side.

## Usage vs. realization

Two different relationships get drawn identically as "depends on the
inner layer's protocol":
- **Usage** (UI→Presentation, Presentation→Domain): the outer layer is
  a *client*, calling through a protocol it does not implement.
- **Realization** (Data→Domain): the outer layer *implements* a
  protocol the inner layer declares — Data is the provider of the
  contract, not a caller.

Both satisfy "depend on protocols, not concretes," but a SOLID review
should know which one it's looking at — they fail differently (a usage
violation smuggles in a concrete call; a realization violation
smuggles in extra surface area beyond the protocol).

## Generic constraint vs. existential — the real difference

Not interchangeable dispatch trivia. Per
[SE-0335](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md)
and [SwiftLee's analysis](https://www.avanderlee.com/swift/existential-any/):

- **`<T: P>` / `some P`** fixes *one* concrete type per instantiation,
  preserved statically. Enables compiler specialization (inlining, no
  indirection) and full support for protocols with associated-type
  requirements.
- **`any P`** type-erases: a single value can hold *different*
  conforming types at runtime (e.g. `[any Shape]` holding circles and
  squares in the same array) — at the cost of a boxed existential
  container, pointer indirection, and dynamic (witness-table) dispatch.
- Before Swift 5.7, a protocol with associated-type requirements (e.g.
  `UseCase<Item>`) **could not** be used as a bare existential without
  hand-written type erasure.
  [SE-0346](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0346-light-weight-same-type-syntax.md)
  (primary associated types) and
  [SE-0353](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0353-constrained-existential-types.md)
  (constrained existential types) made `any P<X>` expressible from
  Swift 5.7 onward.

**Why generics are the default for UI-kit/Presentation abstractions:**
a reusable ViewModel or View is typically parameterized over exactly
*one* concrete domain type per app, wired once at the Composition
Root — precisely the fixed-single-type shape generics were built for.
An existential would pay boxing and dynamic-dispatch cost for
heterogeneous-storage flexibility a single-type-per-app dependency
never exercises. Reach for `any P` only where a value must genuinely
hold *different* conforming types at runtime within the same app
(e.g. a mixed-type list, a type-erased event bus).

## Modern Swift architecture — is layered Clean Architecture still current?

Checked against current (2026) sources, not assumed:
- A 2026 iOS architecture playbook
  ([Forasoft](https://www.forasoft.com/blog/article/advanced-ios-app-architecture-explained-on-mvvm-977))
  independently describes layered Model/Provider/ViewModel/View +
  explicit Composition Root + Swift 6 actors + `@Observable` as the
  2026 production default for apps intended to be maintained —
  matching this doc's direction.
- Apple's own WWDC sample code (Landmarks, Fruta, Food Truck) inspired
  a community-discussed "MV" (Model-View, no ViewModel) pattern, but
  no source found shows Apple explicitly endorsing it for production
  apps — it's a community inference from sample code, not a
  recommended pattern. A community critique
  ([matteomanferdini](https://matteomanferdini.com/swiftui-mv-pattern/))
  argues MV re-invents MVC's problems; treat this source as lower
  confidence (only title/summary accessible, full page 403'd), but
  directionally consistent with keeping ViewModels.
- "Composition Root" is active, current Swift terminology, not a stale
  borrowing from .NET — see
  [Simon B. Støvring's Swift Connection 2023 talk](https://async.techconnection.io/talks/frenchkit/swift-connection-2023/simon-b-stovring-achieving-loose-coupling-with-pure-dependency-injection-and-the-composition-root/)
  built entirely around the term. The modern SwiftUI home for it is
  the `@main App` struct, superseding AppDelegate/SceneDelegate.

## Verification log

This rationale doc exists because earlier drafts of
`coding_standards.md` got two things wrong, caught only by explicit
verification against primary sources rather than internal reasoning:
1. The original diagram drew Data→Presentation→Domain as a dependency
   chain; the prose said Data depends on Domain only. The diagram was
   wrong — fixed by routing Data straight to Domain.
2. A later pass reclassified UI→Presentation and Presentation→Domain
   as *direct* because they use generics — conflating "resolved at
   compile time" with "concrete dependency." Both are abstraction
   dependencies; only a hardcoded concrete type is direct.

Moral: when this file or `coding_standards.md` is revised again, check
claims against Swift Evolution proposals and current sources before
committing them — "sounds right" is not the same as "verified."
