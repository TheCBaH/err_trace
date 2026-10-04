# err_trace

`err_trace` is a dependency-free OCaml library for typed recoverable errors with
optional, bounded provenance. Its public module is `Err`.

Published API documentation: <https://thecbah.github.io/err_trace/err_trace/>.

- Domain errors remain ordinary variants or polymorphic variants.
- Detection origins survive error-domain conversion.
- Semantic events are bounded independently from synchronous monitoring.
- Every public data type has a composable `Format` printer.
- Explicit `~pos:__POS__` locations work under native OCaml, js_of_ocaml, and
  Melange without a PPX.

```ocaml
let decode input =
  Err.of_option ~pos:__POS__ `Missing input

let load input =
  Err.map_error ~pos:__POS__ (fun e -> `Decode e) (decode input)
```

The error payload remains typed: `load` has type `(_, [> `Decode of _ ]) Err.t`.
`Err.Error.kind` recovers that payload; the wrapper retains an optional detection
origin plus a bounded semantic event trail.

For a complete example with nested polymorphic-variant error domains, see
[`examples/poly_errors.ml`](examples/poly_errors.ml). `Base.error` is shared by
modules `A` and `B`; `A` adds its own error domain, while `B` calls `A` and maps
A-specific failures into `B.error`. A single installed monitor logs both
boundaries through `Err.Observation.pp`, using the printer for the domain at
that boundary, while the caller still pattern-matches the structured payload.
The cram tests under [`test/examples`](test/examples) run the same program as
native bytecode, native code, js_of_ocaml, and Melange.

## Install

<!-- $MDX skip -->
```sh
opam install err_trace
```

Melange projects install `err_trace-melange` instead and name that library
(`err_trace-melange`); it provides the same `Err` module.

Add `err_trace` to the `libraries` field of your Dune stanza, then use `Err`.
The library itself only depends on the OCaml standard library and supports OCaml
4.12 and later. OCaml 4.12 is the lower bound because the implementation uses
the standard library's `Atomic` module.

## Trace policy

Tracing is process configuration, not an environment-variable side effect.
Pick one policy during process startup:

- `Err.Config.set Err.Config.fast` records no events at all and captures no
  stacks. It disables the whole semantic trail, not just stack capture.
- `Err.Config.set Err.Config.deterministic` keeps the boundary event trail and
  captures no stacks. This is the production preset for a program that wants
  identical diagnostics on every backend.
- `Err.Config.set Err.Config.default` retains selected boundary events and an
  origin stack.
- `Err.Config.set Err.Config.debug` records every semantic action.

The two sources of nondeterminism are independent: `actions` decides how much
trail is kept, `backtrace` decides whether stacks are captured. The
`fast`/`default`/`debug` ladder bundles them; `deterministic` is the off-diagonal
combination most production programs actually want.

Provenance comes from two places, and `~pos` is the portable one: omitting
`~pos:__POS__` under `backtrace:Never` leaves an error with *no origin at all*,
because there is no stack to fall back on.

`Err.Config.with_config` installs a policy for the duration of a call and
restores the previous one, including when the call raises. It is process-wide,
so it suits tests and startup sequences rather than concurrent code.

For command-line configuration, `Err.Config.of_strings` parses `off`,
`boundaries`, `all`, or comma-separated actions without reading the environment.
Like `Err.Config.make`, it returns `Err.t`: callers can match the
polymorphic-variant configuration error and render its wrapper with
`Err.Error.pp Err.Config.pp_of_strings_error`.
Events are bounded by `max_events`; monitors can still receive enabled events
when that limit is zero. `Never` guarantees no automatic call-stack capture.

```ocaml
let configure () =
  match
    Err.Config.make
      ~actions:Err.Action.Set.boundaries
      ~backtrace:Err.Config.Origin
      ~max_events:32 ~max_frames:32 ~max_external_bytes:(16 * 1024)
  with
  | Ok config -> Err.Config.set config
  | Error error ->
      Format.eprintf "invalid error tracing configuration: %a@."
        (Err.Error.pp Err.Config.pp_make_error) error
```

## Typed printers and conversion

Error printers may themselves use open polymorphic-variant rows. An extended
domain can delegate shared constructors to a base printer while handling its
own constructors locally; `examples/poly_errors.ml` demonstrates this with the
`Base`, `A`, and `B` domains.

Supply the printer for the domain that exists at each event-producing call.
`Err.Error.map_kind` and `Err.map_error` use the destination-domain printer for
the synchronous `Map` observation:

<!-- $MDX skip -->
```ocaml
let mapped =
  Err.Error.map_kind ~pos:__POS__ ~pp_error:Service.pp_error
    Service.error_of_storage storage_error
```

A retained `Map` event does not keep the previous payload or either printer.
This avoids retaining potentially large or sensitive values and printer
closures. If the destination needs structured causal information, encode it in
the destination error variant, for example `` `Storage of Storage.error ``.

`Err.Error.map_kind ~pos:__POS__` is the corresponding primitive when code
already holds an error wrapper; it records the error-domain conversion just as
`Err.map_error` does.

## Binding a domain printer

A domain has exactly one printer, so supplying it at every call is repetitive.
`Err.Make` supplies it once. A module that already has `type error` and
`pp_error` — the shape this library asks a domain to have anyway — satisfies
`Err.Domain` with no extra code:

```ocaml
module Storage = struct
  type error = [ `Missing of string | `Offline ]

  let pp_error ppf = function
    | `Missing key -> Format.fprintf ppf "%s is missing" key
    | `Offline -> Format.pp_print_string ppf "storage is offline"
end

module E = Err.Make (Storage)

let load key : (string, Storage.error) Err.t =
  E.fail ~pos:__POS__ (`Missing key)

let load_exn key = E.or_raise ~pos:__POS__ (load key)
```

`E.fail` is `Err.fail ~pp_error:Storage.pp_error`, so bound and unbound values
are the same values and interoperate freely.

The functor pays best where a module mostly uses one error domain. Binding a
printer fixes `E.fail` at `Storage.error`, so code that relies on
`` `Missing `` first inferring a smaller row and then widening into several
different domains may be clearer with `Err.fail` directly, or with a plain
function wrapper. A printer written with a `[< error ]` argument is accepted by
`Err.Make`; the resulting operations use the domain type supplied to the
functor. `Err.Error.t` is covariant, so a bound value still widens by coercion.

## Escaping a recursive walk

A deeply recursive traversal usually cannot thread a result through every arm
without being rewritten around the monad. `Err.Escape` is the supported exit.
Each `with_escape` call generates its own exception, so nested and concurrent
uses cannot catch one another, and the `Error.t` wrapper is built at the throw
rather than reconstructed at the catch:

```ocaml
type node = Leaf of int | Node of node * node

let sum_positive tree =
  Err.Escape.with_escape (fun token ->
      let rec walk = function
        | Leaf value when value < 0 -> Err.Escape.throw token ~pos:__POS__ (`Negative value)
        | Leaf value -> value
        | Node (left, right) -> walk left + walk right
      in
      walk tree)
```

`Err.Escape.or_throw token result` is the bridge in the other direction: it lets
the walk call ordinary `Err.t`-returning functions, keeping the wrapper they
built. `Err.protect` is the companion for the opposite case — absorbing an
exception raised by *foreign* code rather than establishing an exit for your own.
When a helper's payload row is narrower than its caller's, derive a view with
`Err.Escape.map widen token`; it exits the same frame and records no semantic
`Map` event. For a static polymorphic-variant coercion needed by `or_throw`, a
small wrapper makes the intent explicit without adding an event:

```ocaml
type error = Storage.error

let or_throw token : ('a, [< error ]) Err.t -> 'a = function
  | Ok value -> value
  | Error error ->
      Err.Escape.throw_error token (error :> error Err.Error.t)
```

## Collecting every failure

`Err.List.map`, `iter`, `fold_left`, `map2`, `iter2`, `filter_map`, `exists`, and
`for_all` are stack-safe and stop at the first error. `Err.List.map2` and
`iter2` validate both lengths before invoking their callback,
so an arity error causes no partial effects and cannot be hidden by a callback
failure. A validator or compiler pass usually wants the opposite — every
problem in one report — which is `Err.Accum`:

```ocaml
let validate_all fields =
  Err.Accum.map ~pos:__POS__
    (fun (name, value) ->
      if String.length value = 0 then Err.fail ~pos:__POS__ (`Empty name) else Err.return value)
    fields
```

Its failure is `'e Err.Error.t list`, so each problem keeps its own detection
origin and can be pointed at individually; `Err.Accum.pp_errors` renders them
all. `Err.Accum.lift` brings one ordinary result into this domain, while
`Err.Accum.fold_errors combine` lets a function accumulate internally and
collapse the batch into its published payload domain. The collapsed wrapper
keeps the first failure's provenance.

Every element runs, so side effects and work continue past a failure. Check an
untrusted traversal's size or cost ceiling before entering `Accum`; otherwise
accumulating the walk defeats that ceiling. `Err.bind` is untouched:
accumulation is a sibling of the monadic traversals, not a change to them.

## Crossing a boundary

```ocaml
(* a third-party decoder that returns a bare result *)
let parse input =
  match int_of_string_opt input with Some value -> Ok value | None -> Error "not a number"

let decode_field input =
  Err.import ~pos:__POS__ (fun message -> `Decode message) (parse input)

let to_public result = Err.export ~pos:__POS__ result
```

- `Err.import` lifts a third party's bare `result` and records `Import`.
- `Err.export` records `Export` and then drops the wrapper, so a deliberate
  wrapper drop goes through one named helper instead of being remembered at each
  site. The payload stays typed; rendering is the caller's decision.
- `Err.payload` is the same unwrap without the marking, for tests and rendering.
- `Err.Error.pp_kind` renders the payload with no origin or trail, for a wire
  response or a user-facing message. `Err.Exn.pp_kind` is its exception twin.

`Err.to_exn`, `Err.export_exn`, and `Err.or_raise` provide explicit printable
exception boundaries; most code needs only `or_raise`, and the other three exist
for callers that must build an exception without raising it.

## Niche features

Two areas exist for narrow cases and can be ignored otherwise. `Err.Stack.of_external`
and the `max_external_bytes` limit import a *JavaScript host's* own stack string;
a library or a command-line program never calls them. `Err.to_exn`,
`Err.export_exn`, and `Err.raise_error` are `Err.or_raise` decomposed, for code
that must build or re-raise an exception it already holds.

## Components and checks

`make test-core` includes `mdx`, which compiles this README's `ocaml` code
blocks against the library, so runnable examples stay correct. Blocks that
aren't meant to run (shell commands, fragments referencing a hypothetical
caller-defined module) are marked `<!-- $MDX skip -->`.

Core work needs only Dune and the OCaml formatter:

<!-- $MDX skip -->
```sh
make build
make test-core
make fmt-check
```

On OCaml 5, `make test-multicore` stress-tests concurrent monitor installation,
dispatch, and removal. CI runs it inside each existing OCaml 5 core job.

Framework integrations are intentionally test-only capabilities. Native core
and adapter tests execute under both the bytecode and native runtimes. Their
focused targets install only their own opam dependencies: `test-base-async`,
`test-lwt`, `test-rresult`, `test-cmdliner`, `test-mirage`, `test-octez`, and
`test-fmt-logs-yojson`. JavaScript checks use `make test-js`; Melange is
optional and is reported as skipped when unavailable. `make bench` reports exact
allocation counts for investigation; `make bench-check` enforces only portable
relative invariants and is part of `make ci`.

Native OCaml, js_of_ocaml, and Melange are supported with backend-appropriate
stack fidelity: explicit source positions work everywhere, while native raw
backtraces are naturally richer than JavaScript stacks.

Intentional changes from the original design baseline are recorded in
[`error-changes.md`](error-changes.md).
