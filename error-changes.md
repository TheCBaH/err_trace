# Changes from `.ai/error.md`

`.ai/error.md` remains the original design baseline. The implementation makes
the following intentional changes to that document.

## Caller positions use `~pos`

Error-producing and boundary operations accept `?pos:Source.pos`, normally as
`~pos:__POS__`, instead of `?at:Source.t` and
`~at:(Source.of_pos __POS__)`. `Source.t` remains the representation used by
`Origin`, and adapters with a location captured elsewhere still use
`Origin.make` plus `Error.make_at`.

Motivation: the shorter form keeps the required location explicit at the call
site while removing repetitive wrapping from the dominant use case. It also
preserves the distinction between an OCaml caller position and an origin
imported from another runtime.

## Monitors can receive a current-domain printer

Event-producing operations accept an optional `pp_error`. When supplied, the
synchronous observation can render the complete typed error through
`Observation.pp`; the printer is not retained in `Error.t`. The original design
only guaranteed a printer at exception boundaries.

Motivation: application-installed monitors can log an error when a component
detects it and again when another component maps it, without putting logging in
either component or erasing the payload type. Not retaining the existential
printer keeps error values bounded and avoids extending the lifetime of data
captured by printer closures.

## Configuration constructors return traced typed errors

`Config.make` returns `(Config.t, Config.make_error) Err_trace.t`, and
`Config.of_strings` returns `(Config.t, Config.of_strings_error) Err_trace.t`, rather
than a bare `(Config.t, string) result`. Their error languages are closed
polymorphic variants describing the invalid limit, input spelling, or unknown
mode/action. Both constructors automatically provide their error printer when
they detect a failure.

Motivation: configuration should demonstrate the same typed-error API that the
library asks its users to adopt. Callers can match failures exhaustively,
configuration errors retain provenance under the active policy, and monitors
receive useful text without converting the error to a string prematurely.

## `Error.map_kind` is a recorded conversion

`Error.map_kind` accepts `?pos` and `?pp_error` and records a selected `Map`
event. Top-level `map_error` delegates to it, so one conversion produces exactly
one event. The baseline described `Error.map_kind` as an untraced low-level
operation.

Motivation: changing an error's domain is a semantic conversion even when code
already holds `Error.t`. Silently preserving the trace made this public function
an easy way to lose the conversion point. Recording in the primitive also
prevents different wrappers from implementing inconsistent behavior.

## Every public data type has a printer

In addition to the baseline printers, the API supplies printers for
`Source.pos`, `Action.Set.t`, `Config.backtrace`, `Config.limit`, both
configuration error languages, `Config.t`, `Monitor.t`, `Monitor.callback`, and
the top-level `('a, 'e) Err_trace.t`. Function-valued callbacks are intentionally
rendered as the opaque marker `<callback>`; monitor handles render only their
observable installed/removed state.

Motivation: every public data value can be inspected consistently without
exposing its representation or requiring each adapter and test to invent
formatting. All printers follow the document's self-contained `Format` box
contract.

## OCaml 4.12 is the compiler floor

The main package supports OCaml 4.12 and later rather than coupling its compiler
range to the initial OCaml 4.14 adapter intersection. Core and native adapter
tests execute in bytecode as well as native mode, and the CI matrix includes the
latest OCaml 4.12 patch release.

Motivation: `Atomic` is the newest standard-library API used by the runtime and
was introduced in OCaml 4.12; the remaining runtime APIs and mandatory build
dependencies support that release. Testing the actual lower bound prevents an
unnecessarily restrictive opam constraint and makes bytecode compatibility an
explicit contract. Melange is not a main-package `{with-test}` dependency
because it does not support this compiler floor and the package's `run-test`
command does not enable Melange rules; its dedicated JavaScript devcontainer
continues to install and exercise that optional capability.

The 4.12 developer image pins `pp` to 1.2.0 and `yojson` to 2.2.2. The only
compatible `ocaml-lsp-server` release admits the later breaking `pp.2.0.0` and
`yojson.3.0.0` releases despite being incompatible with their APIs. Pinning
these transitive development tools repairs CI without adding a runtime
dependency or raising the library's compiler floor.

## Octez remains a CI capability, not an opam package

The separate `err_trace-octez-tests` package described by the baseline is not
published. Octez conformance remains available through `make test-octez` and is
run in its dedicated dependency-heavy devcontainer.

Motivation: the auxiliary package would impose ongoing release and solver
maintenance for an uncommon integration without changing the dependency-free
runtime package. The isolated CI capability still catches adapter regressions
without exposing ordinary opam users to the historical Octez dependency
universe.

## Exception-printer registration is eager

The private `Printexc` printer for `Exn.E` is registered once during module
initialization. The baseline's public `Exn.install_printer` function is omitted
because callers have no registration work left to request.

Motivation: claiming a lazy one-time registration with compare-and-set publishes
the "installed" flag before the registration side effect completes. A concurrent
caller could therefore return and render an exception before its printer exists.
Eager registration removes that publication race without adding a threads
dependency or weakening OCaml 4.12 and JavaScript portability; the printer only
matches the library's private exception constructor.

## `Err_trace.Accum` provides applicative accumulation

The baseline lists "accumulating independent validation errors through monadic
bind" among the things it deliberately leaves out, and its "Independent
validation accumulation" section declines to supply an in-library adapter,
proposing that each validator declare
`val validate_all : Input.t -> (unit, validation_error Err_trace.Error.t list) Stdlib.result`
and build items with `Err_trace.Error.make`. The implementation ships `Err_trace.Accum`,
whose traversals return `('b list, 'e Error.t list) Err_trace.t`.

Motivation: `bind` remains short-circuiting, so the baseline's actual
prohibition is honored; the deviation is only about who writes the adapter. Two
independent consumers hand-rolled `errors := e :: !errors` in ten places between
them, and one of them consequently never used the library's traversals at all,
which is the outcome a library should not produce. Returning the library's own
result type rather than a bare `Stdlib.result` keeps a batch outcome composable
with `let*`, `map_error`, `export`, and monitors. Retaining each `Error.t`
rather than the bare payload keeps every failure's own detection origin, which
is what makes a multi-diagnostic report point at each problem; a payload list
would collapse them onto the traversal's own call site.

## `Err_trace.Make` binds one printer per domain

The baseline supplies `pp_error` at each event-producing call and offers no way
to bind it. The implementation adds `Err_trace.Domain`, `Err_trace.S`, and
`Err_trace.Make`, covering exactly the operations that take a printer.

Motivation: a domain has one printer, always. One consumer defined thirteen
private wrappers whose entire purpose was binding that argument and still wrote
`~pp_error` twenty-three times, because the exception-boundary functions take it
as a mandatory argument that no cheap wrapper removes. The functor introduces no
new types -- `Make(D).fail` is `fail ~pp_error:D.pp_error` -- so bound and
unbound values are the same values, and a module that already exposes `error`
and `pp_error` satisfies `Err_trace.Domain` without further work.

The functor pays in modules that mostly use one domain. A printer declared with
a `[< error ]` argument is accepted; the functor's operations are fixed at the
domain type supplied to it. Code that relies on a small inferred row widening
into several different domains may remain clearer with the unbound operations
or a row-preserving one-line wrapper, and `Error.t`'s covariance still allows a
bound value to widen by coercion. A record-shaped binder was rejected outright:
its payload parameter is contravariant, so the natural top-level binding does
not even generalize.

## `Err_trace.Escape` provides a scoped non-local exit

The baseline excludes state monads, general transformers, and an effects
framework, but says nothing about a scoped exception. The implementation adds
`Err_trace.Escape` with `with_escape`, `throw`, `throw_error`, `or_throw`, and the
`Escaped_after_exit` diagnostic.

Motivation: a deeply recursive walk cannot thread a result through every arm
without being rewritten around the monad, so consumers reach for an exception.
Five modules in one repository independently declared the same private exception
and catcher, and one of them carried a bare payload rather than an `Error.t`,
losing the wrapper across its own internal boundary because nothing checked.
`Err_trace.protect` already solved the catching half and had zero uses, which is a
discoverability failure as much as a missing function; the two are now
documented together as one idiom.

Each `with_escape` call generates its own exception, so nested and concurrent
frames cannot catch one another and a throw aimed at an enclosing token reaches
the frame that owns it. Exceptions rather than effect handlers, because
js_of_ocaml and Melange support the former and not the latter and because OCaml
4.12 is the compiler floor. A token used after its frame returns raises
`Escaped_after_exit` at the misuse site rather than unwinding past every
handler. `throw` records `Detect` because the throw is the detection site, and
`with_escape` records nothing: `Catch` describes absorbing a foreign exception,
and recording it would make an escaping walk's trace differ from that of the
equivalent monadic walk.

`Escape.map` lets a helper use a caller token through a narrower error row. The
derived token shares the frame's live cell, widens the wrapper without a `Map`
event, and therefore does not allocate a second generative exception. The docs
also show the explicit coercion wrapper needed when `or_throw` consumes an open
sub-row; that coercion is static and must not masquerade as a semantic map.

## `Err_trace.Accum` can enter and leave its batch domain

Adoption feedback found that the original traversal API made accumulation a
one-way signature change: a locally accumulating validator could not then bind
a sequential ordinary result without changing every public caller to expose an
error list. `Accum.lift` turns one ordinary failure into a one-element batch,
and `Accum.fold_errors` lets the caller collapse collected wrappers into a
payload in its existing domain. The collapse retains the first failure's origin
and event trail and records no `Map` event.

The API documentation now also states the security constraint directly: since
every element runs, a size or cost ceiling for untrusted input must be checked
before entering an accumulating traversal. Accumulation is appropriate only for
the bounded work after that gate.

## `payload`, `import`, `export`, and `Error.pp_kind` are library operations

The baseline's conversion summary treats wrapping at an `Import` boundary and
unwrapping after an `Export` as adapter work. The implementation supplies all
four operations.

Motivation: `Error.kind` was the most-called function in both consumers, and
almost every use sat inside one of two hand-written wrappers -- drop the
provenance, or render the payload. `export` records the `Export` event and then
unwraps, so a deliberate wrapper drop goes through one named helper and the
marking is automatic rather than remembered; that a project rule had to require
such a helper is the evidence that remembering does not work. `payload` is the
deliberately unmarked twin, for tests and rendering, so the marked form is not
diluted by uses that are not boundaries. `import` records only `Import` and no
`Detect`, following `guard`'s precedent, because the failure was detected by
whoever produced the bare result.

`export` keeps the typed payload rather than rendering to a string. Rendering at
the boundary would contradict payload ownership, force `pp_error` to become
mandatory, and add a second entry point for a one-line transformation the caller
can spell itself. `Error.pp_kind` extends `Exn.pp_kind`'s already documented
rationale to the ordinary wrapper, where the same need arises far more often.

## `Config.deterministic` and `Config.with_config`

The baseline offers the `fast`/`default`/`debug` ladder and the `get`/`set`
pair. The implementation adds a fourth preset and a scoped installer.

Motivation: the two sources of nondeterminism -- how much semantic trail is kept,
and whether call stacks are captured -- are independent, but the presets offered
them only as a bundled ladder. The preset named `fast`, described as the
production choice, sets `actions = Action.Set.empty` and therefore discards the
entire event trail rather than only stacks; one consumer nearly shipped it as a
production default believing the opposite. `deterministic` names the policy every
reproducible consumer would otherwise write identically, and `fast` is now
documented as recording no events at all. `default` is unchanged, because it is
the policy in force before any call to `set`.

`with_config` moves a save-and-restore helper that every test suite hand-rolls,
including this repository's own, into the library. It is documented as
process-wide rather than thread- or domain-scoped, so it cannot be mistaken for
a concurrency-safe setter.

## One configuration vocabulary for the disabled state, and liberal parsing

`Config.pp_backtrace` now prints `off` for `Never`, `Config.of_strings` accepts
both `off` and `never`, and the parser trims surrounding whitespace from modes,
action names, and numeric limits while retaining the original invalid input in
diagnostics.

Motivation: printing a policy and feeding it back is the obvious thing for a
tool that logs its configuration or a test that pins one, and it failed on both
axes. The backtrace axis failed because the printer said `never` while the
parser accepted only `off`, so `pp_backtrace`'s own output was rejected by its
own error message's list of alternatives. The trace axis failed for a subtler
reason that no consumer reported: `Action.Set.pp` separates names with a break
hint, which renders as a space, while the parser split on commas alone, so
`Config.pp`'s `trace` field could not be parsed back either. Making the parser
liberal and the printed vocabulary uniform fixes both. The OCaml constructor
stays `Never`, because that is the right word for a guarantee in code, while
`off` is the right word in a configuration string that already spells the same
idea that way on the `trace` axis. Applying the same whitespace rule to numeric
limits makes the public statement that surrounding whitespace is ignored true
for every host-provided setting rather than only for mode names.

## `Err_trace.List` gains two-list and predicate traversals

The baseline lists `map`, `iter`, and `fold_left`. The implementation adds
`map2`, `iter2`, `filter_map`, `exists`, and `for_all`.

Motivation: one consumer had thirty `List.combine`, `List.map2`, and `List.iter2`
sites, several of them immediately preceded by a length check that a monadic
`map2` subsumes. `~unequal_lengths` is a mandatory labelled argument returning a
domain payload, because the library cannot invent a value in the caller's error
domain, silently truncating to the shorter list would be wrong, and raising
`Invalid_argument` would leave the hand-written check exactly where it was.
Both lengths are computed before the traversal begins. This adds a linear
preflight pass on equal-length inputs, but it is what makes the operation truly
subsume the preceding check: no callback side effect occurs on an arity error,
and a callback failure cannot hide the structural mismatch.

`filter` is omitted as subsumed by `filter_map`. `fold_right` is omitted because
it cannot be tail-recursive without reversing the order in which the function
observes the list, which would contradict the module's left-to-right contract in
a module whose stack safety is the reason it exists. The `Seq`, `Array`, and
`Map` families are omitted for want of evidence that they are wanted.

## `Action.Set` derives from one enumeration

`Action.Set.all` was the literal `127`, `boundaries` was a hand-written
disjunction, `Action.Set.pp` inlined the constructor list, and the configuration
parser carried a fourth copy as a string table. All four now derive from one
`order` list and one `to_string` function.

Motivation: four hand-maintained copies of the same enumeration meant adding an
action would compile while silently leaving `all` too small, `boundaries` stale,
one printer short of a case, and one name unparseable. Nothing about the public
interface changes.

## Re-raising reattaches a backtrace only when it has resolvable frames

`Err_trace.protect` and `Err_trace.Escape.with_escape` re-raise the exceptions they do not
absorb. Both previously called `Printexc.raise_with_backtrace` whenever the
active policy had captured a raw backtrace. They now fetch the original raw
backtrace independently of the tracing policy, reattach it when it has
resolvable frames, and otherwise re-raise plainly. The policy still decides
whether a selected exception converted into a typed error retains that stack.

Motivation: `Printexc.raise_with_backtrace` compiles to
`caml_restore_raw_backtrace`, which Melange does not implement. Calling it there
throws "not polyfilled", so the exception the caller finally saw was that error
rather than the one the program raised. Every foreign exception crossing
`protect` on Melange was therefore replaced under any stack-capturing policy,
including `Config.default`, which is the policy in force before any call to
`Config.set`. Conversely, making raw-backtrace retrieval conditional on that
policy caused `Config.Never` -- including the recommended deterministic preset
-- to replace the original native raise site with the library's re-raise site.
Tracing configuration must not alter the semantics of an unrelated exception
that crosses the boundary. The condition reuses the same `backtrace_slots` probe
that `Stack.is_available` already applies for the closely related Melange
divergence in `Printexc.raw_backtrace_length`.

Reattaching only a resolvable backtrace loses nothing: on native code built with
`-g` the behaviour is unchanged, and where the frames cannot be resolved -- a
binary built without `-g`, or a JavaScript backend -- there was no renderable
backtrace to preserve in the first place. Cross-backend tests assert that a
foreign exception keeps its identity through both boundaries, and native tests
also assert that its original raise frame survives under every backtrace policy.

## Allocation checks enforce relational invariants

The baseline treats allocation measurements as informational and rejects
fragile wall-clock thresholds. The implementation keeps the exact-byte report
and adds `bench/allocation_invariants.ml` to ordinary CI.

Motivation: exact allocation counts legitimately change across compiler
versions, word sizes, optimization decisions, and runtimes, so pinning one
number across this repository's matrix would create noise. The relationships
that express the design are much more stable: successful propagation must not
depend on tracing policy, while retaining a source, capturing a stack, or
dispatching monitors must allocate more than the corresponding disabled path.
Enforcing those orderings catches accidental tracing work on success and silent
feature removal without pretending that bytes from different runtimes are
interchangeable.
