# Typed errors with bounded tracing

## About this document

`err_trace` is an OCaml library for typed recoverable errors with optional,
bounded provenance. This document is its reference description: the error model,
runtime configuration, public interface, implementation, printers, exception
boundaries, framework adapters, JavaScript behavior, packaging, and test suite,
together with the reasoning behind each.

`src/err_trace.mli` is authoritative for the interface, `README.md` is the short
introduction, and `error-changes.md` records where the library departs from the
original baseline of this document and why.

## Names

```text
opam package:        err_trace
dune public library: err_trace
dune library name:   err_trace  (unwrapped)
OCaml module:        Err_trace
```

The library is unwrapped, so its single module is `Err_trace` and not a
submodule of a wrapper:

```ocaml
Err_trace.fail ~pos:__POS__ (`Unknown_node id)
Err_trace.map_error ~pos:__POS__ (fun error -> `Decode error) result
Err_trace.Error.kind error
```

## Error representation

The main result type is `('a, 'e) Err_trace.t`, and its wrapped error value is
`'e Err_trace.Error.t`, so `Err_trace.Error.kind` is explicit where code crosses from the
wrapper to its domain payload. Expected, recoverable failures use:

```ocaml
('value, 'error) Err_trace.t
```

where:

```ocaml
type ('value, 'error) t = ('value, 'error Err_trace.Error.t) Stdlib.result
```

`'error` is owned by the component detecting the failure. It is normally a
variant or polymorphic-variant row suitable for exhaustive matching. `Error.t`
adds diagnostic information without erasing that type.

An error contains:

- the current typed payload;
- the original detection site, when configured or explicitly supplied;
- a bounded chronological trail of semantic error events;
- the number of older events discarded by the bound.

Exceptions remain appropriate for programmer errors, invariant violations, and
explicit boundaries whose signatures cannot return a result. Expected errors do
not become exceptions merely for convenience.

## What the library provides

- The compile-time set of expected failures is preserved.
- The first detection site survives while the payload is widened or wrapped.
- Where an error was mapped, filtered, caught, imported, exported, or raised is
  recorded when the application selects those actions.
- Trace memory and rendering cost are bounded.
- Tracing and stack capture are configured independently at runtime.
- Any number of removable monitors are notified synchronously at selected error
  events, optionally with the payload printer of the domain at that boundary.
- Successful `map`, `bind`, and traversal paths allocate no tracing data.
- Explicit exception boundaries produce printable structured exceptions, which
  can also be constructed without raising them.
- Every public data type has a self-contained, composable `Format` printer,
  including the library's own configuration errors.
- Native OCaml, js_of_ocaml, and Melange are supported, with documented
  degradation of stack fidelity.
- The runtime package has no third-party dependencies.

## What it deliberately leaves out

- One global application error variant.
- Converting every exception into an expected result.
- Recording ordinary propagation steps.
- Choosing a logging backend or writing to stderr on its own.
- Native-quality stack frames on JavaScript backends.
- Stack strings as a basis for programmatic classification.
- Accumulating independent validation errors through monadic bind.
- State monads, general transformers, or an effects framework.
- Native backtraces as a public wire format.
- Interception of runtime exceptions that never cross an `Err_trace` API.

## Error model

### Typed payload

Every domain owns its error type and printer:

```ocaml
type error =
  [ `Missing_field of string
  | `Invalid_shape of int list
  ]

let pp_error ppf = function
  | `Missing_field field ->
      Format.fprintf ppf "missing field %S" field
  | `Invalid_shape shape ->
      Format.fprintf ppf "invalid shape of rank %d" (List.length shape)

val decode : Json.t -> (Tensor.t, error) Err_trace.t
```

The wrapper never replaces the domain printer or turns the payload into a
string. `Error.t` retains no printer: presentation happens when a caller
supplies `pp_error`, either to a printing function or to an event-producing
operation that forwards it to monitors for that one dispatch.

### Source location

`Err_trace.Source.t` is a cheap, backend-independent source coordinate. Every
error-producing and boundary operation accepts the unwrapped `__POS__` value
directly:

```ocaml
Err_trace.fail ~pos:__POS__ (`Unknown_node id)
```

`Source.pos` is `string * int * int * int`: file, line, start column, and end
column, the type of OCaml's built-in `__POS__`. It requires no PPX and becomes a
constant at compile time. `Source.of_pos` converts it to the stored `Source.t`,
which adapters use when a location was captured by other means:

```ocaml
Err_trace.Source.of_pos ("parser.ml", 4, 3, 8)
```

Locations are explicit because an optional argument's default expression would
run inside the library, not at the caller. `~pos` keeps the required location
visible at the call site without repeating a wrapper call. An optional PPX
adapter could insert these arguments, but it is not a dependency of the package.

### Origin

`Err_trace.Origin.t` describes one semantic site. It may contain:

- an explicit `Source.t`;
- an OCaml `Printexc.raw_backtrace`;
- an external stack string, such as JavaScript `Error.stack`;
- both an explicit source coordinate and a stack.

The representation is abstract, and `Origin.make` returns `None` when neither
component is supplied. External stacks are tagged by runtime and bounded before
storage. An unavailable stack is valid and printable: `Stack.is_available`
reports whether a stack carries usable frames, and an unavailable one renders a
notice instead of frames.

### Trace event

An event records a semantic transition, not mere data flow:

```ocaml
type Action.t =
  | Detect
  | Map
  | Filter
  | Catch
  | Raise
  | Import
  | Export
```

Each event has an optional `Origin.t`. Events are retained newest-first
internally for cheap insertion and rendered chronologically.

### Which operations add events

An operation records an event when it changes the meaning or representation of a
failure, not when it merely propagates one. Every event is subject to the
process action selection: an action absent from `Config.actions` creates neither
a retained event nor a monitor notification.

| Operation | Event | When recorded |
|---|---|---|
| `fail`, `Error.make`, failed `of_option` / `map_none` | `Detect` | When the failure is created |
| `map_error`, `Error.map_kind` | `Map` | Only on the `Error` branch, at the conversion point |
| `guard` | `Filter` | Only when the condition rejects |
| `protect` | `Catch` | Only for an exception selected by the classifier |
| `mark_error Import` | `Import` | When an external framework error enters the model |
| `mark_error Export` | `Export` | Immediately before a lossy framework conversion |
| `to_exn` / failed `export_exn` | `Export` | Before packing a structured exception without raising it |
| `or_raise` / `raise_error` | `Raise` | Immediately before the structured exception is raised |
| `Error.make_at` | none | Adapter constructor for a site captured elsewhere |
| `return`, successful `map`, successful `bind` | none | They do not touch an error |
| error propagation through `bind`, `map`, or list traversal | none | Recording every propagation step creates noise and unbounded cost |

`map_error` retains only the new typed payload. It does not retain prior
payloads or printers: those may be large, sensitive, or impossible to print with
the new payload's printer. The `Map` event states where the semantic wrapping
occurred; nested variants such as `` `Decode error `` retain machine-readable
causal structure.

`Error.map_kind` is the same conversion expressed on a wrapper the caller
already holds, so it records the event itself and `map_error` delegates to it.
One conversion therefore produces exactly one event regardless of which entry
point the caller used.

### Bounded trace

Every error stores at most `Config.max_events` events. Insertion trims to the
bound currently configured, so lowering `max_events` between events immediately
discards the excess history rather than waiting for it to age out. Each
discarded event increments a counter. The original detection origin is stored
separately and is never evicted. The counter saturates at `max_int` rather than
wrapping, including on 32-bit and JavaScript runtimes.

Keeping the newest bounded events is preferable because the final
classification, export, and raise boundary are often the most actionable after
the original detection site. Printing reports the number of dropped events.

### Event monitors

Monitors observe semantic error events and can feed logs, metrics, traces, or a
debugger. They are notification hooks, not owners of errors. Every event
selected by `Config.actions` is dispatched synchronously to every installed
monitor whose own action filter selects it.

Event retention and observation are deliberately independent. With an enabled
action and `max_events = 0`, the event is sent to monitors, is not retained in
the error, and increments `dropped_events`. This supports production telemetry
without growing error values.

An `Observation.t` contains the current event, the error's detection origin, the
retained event snapshot, and its dropped-event count. Every event-producing
operation accepts an optional `pp_error` for the payload domain that exists at
that call. When supplied, `Observation.pp` renders the complete typed error;
otherwise it renders the event and available trace metadata, because the library
cannot print an arbitrary typed payload without its domain printer. The printer
is used for that dispatch only and is not retained by `Error.t`, so error values
stay bounded and printer closures do not extend the lifetime of captured data.

Multiple monitors may be installed. Installation returns a handle; removing the
handle is idempotent and does not disturb other monitors. Callbacks run in
installation order against a registry snapshot. Installing or removing a monitor
inside a callback affects the next event, not the current dispatch.

Callbacks run synchronously on the thread/domain producing the event and must be
short and non-blocking. A callback that wants asynchronous logging should enqueue
a bounded rendered or structured snapshot. Callback exceptions never replace the
application's result or exception: the failing monitor is removed, then its
optional `on_error` hook receives the callback exception and a stack when the
active backtrace policy permits one. The default hook does nothing, and an
exception from `on_error` is ignored. A monitor callback must not invoke an
event-producing `Err_trace` operation; doing so is unsupported re-entrancy.

## Runtime configuration

Tracing events and capturing stacks are separate decisions.

### Trace selection

`Config.actions` is an `Action.Set.t`, represented as an immutable bit set. An
empty set disables event allocation. Individual actions can be selected; for
example, an application may trace only `Map`, `Filter`, and `Raise`.

Four presets are provided:

| Preset | Actions | Intended use |
|---|---|---|
| `Config.fast` | none | Cheapest policy; disables the whole trail, not the recommended production preset |
| `Config.deterministic` | `Action.Set.boundaries` | Recommended production preset and start-up policy, no stacks |
| `Config.with_stacks` | `Action.Set.boundaries` | Boundary trail plus origin stacks (was `default`) |
| `Config.debug` | `Action.Set.all` | Debugging and tests |

`Action.Set.boundaries` is every action except `Detect`. The complete presets
are:

- `fast`: no actions, `Never`, 0 events, 0 frames, 16 KiB external stacks;
- `deterministic`: boundary actions, `Never`, 32 events, 0 frames, 16 KiB
  external stacks;
- `with_stacks`: boundary actions, `Origin`, 32 events, 32 frames, 16 KiB
  external stacks (named `default` before the start-up policy changed);
- `debug`: all actions, `Events`, 64 events, 64 frames, 16 KiB external stacks.

`Config.deterministic` is the recommended production preset and the
configuration installed at program start.

### Backtrace mode

```ocaml
type Config.backtrace =
  | Never
  | Origin
  | Events
```

- `Never` never calls `Printexc.get_callstack` automatically. Explicit `~pos`
  locations and imported external stacks still work.
- `Origin` captures a stack only when a new failure is detected or a selected
  exception is caught. Mapping/filtering events use only explicit `~pos`
  locations.
- `Events` captures the origin and a stack for every enabled event. An explicit
  `~pos` source is stored alongside that stack. This is the most expensive mode.

An explicit `~pos` does not force a stack capture. It supplies a cheap source
coordinate regardless of backtrace mode.

### Limits

`Config.t` contains:

```ocaml
actions            : Action.Set.t
backtrace          : Config.backtrace
max_events         : int
max_frames         : int
max_external_bytes : int
```

All limits are validated as non-negative and no greater than `0x3fff_ffff`, so a
configuration accepted on a 64-bit runtime is representable on a 32-bit OCaml
runtime. A stack is truncated before it enters an error value: `capture` asks
the runtime for at most `max_frames` frames, and `protect` cuts the caught
stack to `max_frames` slots after the classifier claims the exception (an
unclaimed exception is re-raised with its full original trace). A cut stack has
no `raw_backtrace` form, so `Stack.to_raw_backtrace` returns `None` for it.

### Typed configuration errors

`Config.make` and `Config.of_strings` return the library's own result type
rather than `(t, string) result`:

```ocaml
type limit = [ `Max_events | `Max_frames | `Max_external_bytes ]

type make_error =
  [ `Negative_limit of limit * int
  | `Limit_too_large of limit * int ]

type of_strings_error =
  [ make_error
  | `Invalid_limit of limit * string
  | `Unknown_backtrace_mode of string
  | `Unknown_trace_action of string ]
```

`of_strings_error` includes `make_error`, so a caller that only handles
construction limits can widen its own error row. Both constructors attach their
printer (`pp_make_error`, `pp_of_strings_error`) when they detect a failure, so
monitors and `Error.pp` can render configuration failures without the caller
converting them to strings first. The library dog-foods its own model: its
configuration errors are exhaustively matchable and carry provenance under the
active policy.

### Process configuration

Configuration is held in an `Atomic.t` and read only on failure/event paths.
`Config.set` is intended for process startup, before concurrent work begins.
Changing it while an error is moving through the system is supported but may
produce a deliberately mixed trace: already stored events remain, while later
events follow the new policy and are trimmed to the new bound.

The library does not read environment variables automatically. Browser runtimes
do not have a uniform process environment, and a reusable library should not
silently change behavior because of host state. Applications may map these
recommended runtime flags to `Config.t`:

```text
ERR_TRACE=off|boundaries|all|map,filter,raise,...
ERR_BACKTRACE=off|origin|events
ERR_MAX_EVENTS=<non-negative integer>
ERR_MAX_FRAMES=<non-negative integer>
ERR_MAX_EXTERNAL_BYTES=<non-negative integer>
```

`Config.of_strings` parses these values without reading the environment, so CLI,
server, browser, and test hosts can obtain configuration through their normal
mechanisms. Action names are the lowercase constructor names (`detect`, `map`,
`filter`, `catch`, `raise`, `import`, `export`). An absent argument takes its
value from `Config.deterministic`, not from the currently installed configuration, so
parsing the same host settings twice yields the same policy.

### Performance expectations

- Successful `return`, `map`, `bind`, `of_option`, `guard`, and list traversals
  allocate no trace data.
- Propagating an existing error through `bind` does not read configuration.
- `map_error` reads configuration only on its `Error` branch.
- With `actions = empty`, mapping allocates only the new error wrapper required
  to hold the changed payload; it does not allocate an event or read the monitor
  registry.
- With `backtrace = Never`, no `Printexc.get_callstack` call occurs.
- `fail` and `Error.make` read the configuration once for both origin capture
  and the `Detect` event.
- Event storage and rendering are bounded by configured limits.
- An enabled event reads one monitor-registry snapshot. With no matching
  monitor, it allocates no observation and calls no payload printer; with
  monitors, observation and callback cost occurs only on the failure path.

These are observable performance contracts; `bench/allocation.ml` measures them.

## Public interface

`src/err_trace.mli` is the authoritative interface. The listing below elides
documentation comments; `Located` and the functor `Make`/`Domain`/`S` are only
summarized after it.

```ocaml
module Source : sig
  type pos = string * int * int * int
  type t

  val of_pos : pos -> t
  val to_pos : t -> pos
  val pp_pos : Format.formatter -> pos -> unit
  val pp : Format.formatter -> t -> unit
end

module Stack : sig
  type t

  val of_raw_backtrace : Printexc.raw_backtrace -> t
  val of_external : runtime:string -> stack:string -> t
  val to_external : t -> (string * string * bool) option
  val is_available : t -> bool
  val to_raw_backtrace : t -> Printexc.raw_backtrace option
  val pp : Format.formatter -> t -> unit
end

module Origin : sig
  type t

  val make : ?source:Source.t -> ?stack:Stack.t -> unit -> t option
  val source : t -> Source.t option
  val stack : t -> Stack.t option
  val pp : Format.formatter -> t -> unit
end

module Action : sig
  type t = Detect | Map | Filter | Catch | Raise | Import | Export

  (* The actions mark_error may add to an existing error. *)
  type marking = [ `Filter | `Catch | `Import | `Export ]

  val pp : Format.formatter -> t -> unit

  module Set : sig
    type action = t
    type t

    val empty : t
    val all : t
    val boundaries : t
    val of_list : action list -> t
    val mem : action -> t -> bool
    val add : action -> t -> t
    val remove : action -> t -> t
    val union : t -> t -> t
    val to_list : t -> action list
    val equal : t -> t -> bool
    val pp : Format.formatter -> t -> unit
  end
end

module Event : sig
  type t

  val action : t -> Action.t
  val origin : t -> Origin.t option
  val pp : Format.formatter -> t -> unit
end

module Error : sig
  type +'e t

  val make :
    ?pos:Source.pos ->
    ?pp_error:(Format.formatter -> 'e -> unit) ->
    'e ->
    'e t

  (** Adapter constructor for a site already captured by another
      runtime/framework. It records no event and must not be used to rewrap an
      existing [Error.t]. *)
  val make_at : origin:Origin.t option -> 'e -> 'e t

  val kind : 'e t -> 'e
  val origin : 'e t -> Origin.t option

  (** Events in chronological order, oldest retained event first. *)
  val events : 'e t -> Event.t list
  val dropped_events : 'e t -> int

  (** Change the payload, preserve origin/events, and record [Map]. *)
  val map_kind :
    ?pos:Source.pos ->
    ?pp_error:(Format.formatter -> 'b -> unit) ->
    ('a -> 'b) ->
    'a t ->
    'b t

  val pp : (Format.formatter -> 'e -> unit) -> Format.formatter -> 'e t -> unit

  (** The domain payload alone, without origin or events. *)
  val pp_kind : (Format.formatter -> 'e -> unit) -> Format.formatter -> 'e t -> unit
end

type ('a, 'e) t = ('a, 'e Error.t) result

module Config : sig
  type backtrace = Never | Origin | Events
  type t
  type limit = [ `Max_events | `Max_frames | `Max_external_bytes ]

  type make_error =
    [ `Negative_limit of limit * int | `Limit_too_large of limit * int ]

  type of_strings_error =
    [ make_error
    | `Invalid_limit of limit * string
    | `Unknown_backtrace_mode of string
    | `Unknown_trace_action of string
    | `Empty_trace_action of int ]

  val pp_backtrace : Format.formatter -> backtrace -> unit
  val pp_limit : Format.formatter -> limit -> unit
  val pp_make_error : Format.formatter -> make_error -> unit
  val pp_of_strings_error : Format.formatter -> of_strings_error -> unit

  val make :
    actions:Action.Set.t ->
    backtrace:backtrace ->
    max_events:int ->
    max_frames:int ->
    max_external_bytes:int ->
    (t, make_error Error.t) result

  val fast : t
  val deterministic : t  (* start-up policy; recommended for production *)
  val with_stacks : t
  val debug : t
  val get : unit -> t
  val set : t -> unit
  val with_config : t -> (unit -> 'a) -> 'a

  val actions : t -> Action.Set.t
  val backtrace : t -> backtrace
  val max_events : t -> int
  val max_frames : t -> int
  val max_external_bytes : t -> int
  val pp : Format.formatter -> t -> unit

  val of_strings :
    trace:string option ->
    backtrace:string option ->
    max_events:string option ->
    max_frames:string option ->
    max_external_bytes:string option ->
    (t, of_strings_error Error.t) result
end

module Observation : sig
  type t

  val event : t -> Event.t
  val error_origin : t -> Origin.t option
  val retained_events : t -> Event.t list
  val dropped_events : t -> int
  val is_creation : t -> bool

  (** Render the complete error when the producing operation supplied a payload
      printer; otherwise render the event and available trace metadata. *)
  val pp : Format.formatter -> t -> unit
end

module Monitor : sig
  type t
  type callback = Observation.t -> unit

  (** [actions] defaults to [Action.Set.all]. *)
  val install :
    ?actions:Action.Set.t ->
    ?on_error:(exn -> Stack.t option -> unit) ->
    ?on_failure:(exn -> [ `Keep | `Remove ]) ->
    callback ->
    t

  val last_failure : t -> (exn * Stack.t option) option

  (** Return [true] only for the call that transitions an installed monitor to
      removed. Further removals return [false]. *)
  val remove : t -> bool

  val pp : Format.formatter -> t -> unit
  val pp_callback : Format.formatter -> callback -> unit
end

val pp :
  (Format.formatter -> 'a -> unit) ->
  (Format.formatter -> 'e -> unit) ->
  Format.formatter ->
  ('a, 'e) t ->
  unit

val return : 'a -> ('a, 'e) t

val fail :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'e -> unit) ->
  'e ->
  ('a, 'e) t

(** Eager in the error payload. *)
val of_option :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'e -> unit) ->
  'e ->
  'a option ->
  ('a, 'e) t

(** Map only [None] to an error. The thunk is not called for [Some _]. *)
val map_none :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'e -> unit) ->
  error:(unit -> 'e) ->
  'a option ->
  ('a, 'e) t

val guard :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'e -> unit) ->
  error:'e ->
  bool ->
  (unit, 'e) t

val map : ('a -> 'b) -> ('a, 'e) t -> ('b, 'e) t
val bind : ('a, 'e) t -> ('a -> ('b, 'e) t) -> ('b, 'e) t

(** Preserve the original detection origin and record [Map] when selected. *)
val map_error :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'f -> unit) ->
  ('e -> 'f) ->
  ('a, 'e) t ->
  ('a, 'f) t

(** Record an adapter/boundary action when selected. No-op on [Ok]. *)
val mark_error :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'e -> unit) ->
  Action.marking ->
  ('a, 'e) t ->
  ('a, 'e) t

(** Drop the wrapper, keep the typed payload, record no event. *)
val payload : ('a, 'e) t -> ('a, 'e) Stdlib.result

(** Lift a bare result, mapping its error; records [Import], no [Detect]. *)
val import :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'f -> unit) ->
  ('e -> 'f) ->
  ('a, 'e) Stdlib.result ->
  ('a, 'f) t

(** Record [Export], then drop the wrapper. *)
val export :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'e -> unit) ->
  ('a, 'e) t ->
  ('a, 'e) Stdlib.result

(** Convert only selected exceptions. Unselected exceptions are re-raised with
    the best backtrace representation available on the backend. *)
val protect :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'e -> unit) ->
  catch:(exn -> 'e option) ->
  (unit -> 'a) ->
  ('a, 'e) t

module Exn : sig
  type packed
  exception E of packed

  val pp : Format.formatter -> packed -> unit

  val origin : packed -> Origin.t option
  val events : packed -> Event.t list
  val dropped_events : packed -> int

  (** The domain payload alone, without origin or events. *)
  val pp_kind : Format.formatter -> packed -> unit
end

(** Record [Export], notify monitors with [pp_error], and construct [Exn.E]
    without raising it. *)
val to_exn :
  ?pos:Source.pos ->
  pp_error:(Format.formatter -> 'e -> unit) ->
  'e Error.t ->
  exn

(** Preserve [Ok]. Convert [Error] through [to_exn]. *)
val export_exn :
  ?pos:Source.pos ->
  pp_error:(Format.formatter -> 'e -> unit) ->
  ('a, 'e) t ->
  ('a, exn) result

(** Record [Raise], construct [Exn.E], and raise it. *)
val raise_error :
  ?pos:Source.pos ->
  pp_error:(Format.formatter -> 'e -> unit) ->
  'e Error.t ->
  'a

val or_raise :
  ?pos:Source.pos ->
  pp_error:(Format.formatter -> 'e -> unit) ->
  ('a, 'e) t ->
  'a

module Syntax : sig
  val ( let* ) : ('a, 'e) t -> ('a -> ('b, 'e) t) -> ('b, 'e) t
  val ( let+ ) : ('a, 'e) t -> ('a -> 'b) -> ('b, 'e) t
  val ( >>= ) : ('a, 'e) t -> ('a -> ('b, 'e) t) -> ('b, 'e) t
  val ( >>| ) : ('a, 'e) t -> ('a -> 'b) -> ('b, 'e) t
end

module List : sig
  val map : ('a -> ('b, 'e) t) -> 'a list -> ('b list, 'e) t
  val iter : ('a -> (unit, 'e) t) -> 'a list -> (unit, 'e) t

  val fold_left :
    ('acc -> 'a -> ('acc, 'e) t) -> 'acc -> 'a list -> ('acc, 'e) t

  (** A length mismatch is a detected error built by [unequal_lengths]. *)
  val map2 :
    ?pos:Source.pos ->
    ?pp_error:(Format.formatter -> 'e -> unit) ->
    unequal_lengths:(int -> int -> 'e) ->
    ('a -> 'b -> ('c, 'e) t) ->
    'a list ->
    'b list ->
    ('c list, 'e) t

  val iter2 :
    ?pos:Source.pos ->
    ?pp_error:(Format.formatter -> 'e -> unit) ->
    unequal_lengths:(int -> int -> 'e) ->
    ('a -> 'b -> (unit, 'e) t) ->
    'a list ->
    'b list ->
    (unit, 'e) t

  val filter_map : ('a -> ('b option, 'e) t) -> 'a list -> ('b list, 'e) t
  val exists : ('a -> (bool, 'e) t) -> 'a list -> (bool, 'e) t
  val for_all : ('a -> (bool, 'e) t) -> 'a list -> (bool, 'e) t
end

(** Run every element and report every failure, in input order. *)
module Accum : sig
  type 'e errors = 'e Error.t list

  val pp_errors : (Format.formatter -> 'e -> unit) -> Format.formatter -> 'e errors -> unit
  val map : ?pos:Source.pos -> ('a -> ('b, 'e) t) -> 'a list -> ('b list, 'e errors) t
  val iter : ?pos:Source.pos -> ('a -> (unit, 'e) t) -> 'a list -> (unit, 'e errors) t
  val all : ?pos:Source.pos -> ('a, 'e) t list -> ('a list, 'e errors) t
  val both : ?pos:Source.pos -> ('a, 'e) t -> ('b, 'e) t -> ('a * 'b, 'e errors) t
  val lift : ('a, 'e) t -> ('a, 'e errors) t
  val fold_errors : ('e errors -> 'f) -> ('a, 'e errors) t -> ('a, 'f) t

  module Syntax : sig
    val ( let+ ) : ('a, 'e errors) t -> ('a -> 'b) -> ('b, 'e errors) t
    val ( and+ ) : ('a, 'e errors) t -> ('b, 'e errors) t -> ('a * 'b, 'e errors) t
  end
end

(** Scoped non-local exit; the companion of [protect] for the current module. *)
module Escape : sig
  type 'e t
  exception Escaped_after_exit of Source.t option

  val with_escape : ('e t -> 'a) -> ('a, 'e Error.t) result
  val throw : 'e t -> ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'e -> unit) -> 'e -> 'a
  val throw_error : ?pos:Source.pos -> 'e t -> 'e Error.t -> 'a
  val or_throw : ?pos:Source.pos -> 'e t -> ('a, 'e Error.t) result -> 'a
  val map : ('e -> 'f) -> 'f t -> 'e t
  val pp : Format.formatter -> 'e t -> unit
end

(** Count of events recorded without [?pos]. *)
module Stats : sig
  val unlocated : unit -> int
  val reset_unlocated : unit -> unit
end
```

Two further items are described by `src/err_trace.mli` and not repeated here:

- `Located` repeats the operations that take `?pos` (`fail`, `of_option`,
  `map_none`, `guard`, `map_error`, `mark_error`, `import`, `export`,
  `protect`, `throw`, `throw_error`, `or_throw`, `to_exn`, `export_exn`,
  `raise_error`, `or_raise`) with `~pos` mandatory, so omitting it is a type
  error;
- `module type Domain` (`type error` and `pp_error`) and the functor
  `Make (D : Domain) : S with type error = D.error` bind a domain printer once:
  `S` has the printer-taking operations of `Err_trace`, `Err_trace.Error` and `Err_trace.List`
  (`map2`, `iter2`) with `?pp_error` already supplied.

There is no `Exn.install_printer`. The `Printexc` printer for `Exn.E` is
registered during module initialization, so callers have no registration work
left to request.

## Implementation

### Internal representation

The central type is:

```ocaml
module Error = struct
  type +'e t = {
    kind : 'e;
    origin : Origin.t option;
    events_rev : Event.t list;
    event_count : int;
    dropped_events : int;
  }
end
```

The public signature keeps this record abstract. Consumers cannot update `kind`
directly and accidentally rebuild provenance.

`event_count` avoids repeatedly measuring the list. Since the configured bound
is small, retaining the newest events uses a bounded `take` when the limit is
crossed. The failure-only cost is `O(max_events)` in the overflow case and
`O(1)` otherwise. A ring buffer is unnecessary until measurement shows this path
matters.

`Stack.t` is either a native `Printexc.raw_backtrace` or an external record
holding the runtime label, the bounded stack text, and whether truncation
occurred. `Action.Set.t` is an integer bit set.

### Capturing an origin

```ocaml
let capture config ?source purpose =
  let stack =
    match config.backtrace, purpose with
    | Never, _ | Origin, `Event -> None
    | Origin, `Origin | Events, _ ->
        Some
          (Stack.of_raw_backtrace
             (Printexc.get_callstack config.max_frames))
  in
  Origin.make ?source ?stack ()
```

An imported JavaScript or framework stack calls `Origin.make` with
`Stack.of_external` rather than capturing an OCaml call stack.
`Stack.of_external` truncates according to the configuration current at import
time and records that truncation for printing.

### Stack availability

`Stack.is_available` and `Stack.pp` decide whether a native stack has usable
frames through `Printexc.backtrace_slots`, not `Printexc.raw_backtrace_length`.
Melange compiles `raw_backtrace_length` to `bt.length` while its `get_callstack`
yields `undefined`, so asking for the length threw a `TypeError` out of a
printer — a crash in diagnostic code, on the path taken when something has
already gone wrong. `backtrace_slots` converts defensively, answers `None`
there, and is safe on all three backends.

The same predicate is slightly stricter natively: a binary built without `-g`
has frames the runtime cannot symbolize, and those now count as unavailable,
which is what the predicate is used to decide. An unavailable stack is never an
error-handling failure; it only changes what the printer emits.

### Adding and dispatching an event

```ocaml
let add_event ?config ?pos ?pp_error action error =
  let config =
    match config with Some config -> config | None -> Atomic.get current_config
  in
  if not (Action.Set.mem action config.actions) then error
  else
    let source = Option.map Source.of_pos pos in
    let event = { Event.action; origin = capture config ?source `Event } in
    (* prepend, trim to config.max_events, saturate dropped_events *)
    let error = insert_bounded config event error in
    let printer =
      match pp_error with
      | None -> None
      | Some pp_error -> Some (fun ppf -> pp pp_error ppf error)
    in
    !event_dispatch event error.origin (events error) error.dropped_events
      printer;
    error
```

The optional `config` argument lets `Error.make` read the configuration once for
both origin capture and its `Detect` event.

Dispatch happens after bounded insertion, so the snapshot observed by a monitor
contains the current event when it is retained. `max_events = 0` stores no event
but still increments `dropped_events` and dispatches through
`Observation.event`. This makes the limit an absolute memory bound rather than a
switch for telemetry.

`Error` is defined before `Config`, `Observation`, and `Monitor`, so dispatch
goes through an `event_dispatch` function reference that is set once at module
initialization. The indirection exists only to break the definition order; it is
not a user-visible hook.

The optional payload printer is passed to the observation as a pre-bound
closure over the fully updated error, so the existential payload type never
escapes and `Observation.pp` needs no additional type information.

### Monitor registry

The registry is an `entry list Atomic.t`. Each entry contains a
`bool Atomic.t` active flag, an action filter, the callback, and its failure
hook. Installation prepends an entry with a compare-and-set retry and returns
that entry as an opaque handle. Removal atomically flips the active flag and
then removes the physically matching entry with another compare-and-set retry;
its Boolean result makes idempotence observable.

Dispatch reads one registry snapshot, keeps the active entries whose filter
selects the action, reverses them into installation order, and invokes the
callbacks. The observation is constructed only when at least one entry matches.
Dispatch does not hold a lock while calling user code. Concurrent removal may
therefore overlap one already-started dispatch, but after `remove` returns, a
later dispatch snapshot will not select that monitor. This is the ordinary
snapshot guarantee; removal does not wait for an in-flight callback.

Each callback invocation is protected. If the callback raises, dispatch obtains
its stack immediately only when the current backtrace mode is not `Never` and
the runtime supplies one, removes that entry, then invokes `on_error`. Neither
callback failure nor failure-hook failure is converted into an `Err_trace` event,
which avoids recursive failure storms. A monitor that calls an event-producing
`Err_trace` function directly violates the API's non-reentrancy contract.

### Constructors

`fail ?pos kind` delegates to `Error.make`, which reads configuration once,
captures the detection origin according to `backtrace`, constructs the wrapper,
and records `Detect` when selected.

`of_option` and `map_none` inspect the option before constructing a wrapper. The
eager form may evaluate its payload on success; `map_none ~error` does not
invoke its thunk for `Some _`. A `None` result records `Detect` under the same
rules as `fail`.

`guard ~error condition` returns `Ok ()` when true. When false it captures the
detection origin and records `Filter` rather than separately recording `Detect`
and `Filter`; the origin remains the detection site, while `Filter` names why
this constructor rejected. Recording `Filter` alone avoids duplicate adjacent
events even when `Detect` is also selected.

### Mapping

```ocaml
let map_error ?pos ?pp_error f = function
  | Ok value -> Ok value
  | Error error -> Error (Error.map_kind ?pos ?pp_error f error)
```

`Error.map_kind` replaces the payload, retains the original origin and prior
events, and then records `Map` on the new wrapper. The `Ok` branch reads no
configuration.

### Filtering and recovery

Filtering successful values into an error records `Filter`. Merely inspecting an
error and deciding to propagate it records nothing. A recovery combinator that
consumes an error and produces `Ok` cannot attach an event to the vanished
error; if recovery auditing is needed, that belongs in logging/telemetry rather
than an error value that no longer exists.

### Exception import

`protect` reads the configuration once, at the moment an exception is caught, so
a classifier that changes the process policy cannot retroactively affect this
capture. It always records `Printexc.get_raw_backtrace ()` immediately after
catching, before invoking the classifier, whatever the backtrace mode. If the
classifier returns `None`, the exception is re-raised through `reraise`, which
reattaches the backtrace with `Printexc.raise_with_backtrace` when it has
resolvable frames and uses plain `raise` otherwise. If selected:

- `backtrace = Never` retains no stack;
- otherwise (`Origin` or `Events`) the raw backtrace, cut to `max_frames` slots
  after the classifier has claimed the exception, becomes the error origin
  (none when `max_frames = 0`), alongside an explicit `~pos` when supplied;
- a `Catch` event records the catch boundary when selected.

Re-raising does not depend on the backtrace mode, so an unselected native
exception keeps its original raise site wherever the runtime has a backtrace to
reattach. A JavaScript `Error` object generally retains its own `stack`
property independently.

Backend-specific JavaScript exception adapters should inspect JavaScript error
objects before falling back to generic `protect`, because their useful stack is
not necessarily available through `Printexc`.

### Framework import and export

Adapters use `mark_error Import` or `mark_error Export`. An adapter importing a
bare external error normally constructs a new `Error.t` whose origin is the
adapter boundary. An adapter importing an existing external stack or a location
captured by another tool uses `Origin.make` plus `Error.make_at`, which records
no event of its own.

Export often discards the wrapper. It should first mark `Export`, render or
encode the resulting value, and perform the loss in one named helper.

`to_exn` is the standard exception export. It records `Export`, passes the
supplied payload printer to monitors, and packs the resulting wrapper into
`Exn.E` without raising it. `export_exn` maps this operation over the `Error`
branch of a result. These functions are for APIs that consume `exn`;
`raise_error` records `Raise` instead and is not implemented through `to_exn`,
because that would invent an `Export` event before every raise.

## Printable exceptions

### Structured exception

The exception stores the full error and the payload printer existentially:

```ocaml
module Exn = struct
  type packed =
    | Pack : 'e Error.t * (Format.formatter -> 'e -> unit) -> packed

  exception E of packed
end
```

Packing is deliberately not public because callers could otherwise bypass the
`Export`/`Raise` event. `Exn.pp` delegates to `Error.pp` and can therefore
render the typed payload, detection origin, mapping/filter trail, and boundary
location. Callers use `to_exn`, `export_exn`, `raise_error`, or `or_raise`,
which record the appropriate event and notify monitors.

`Exn.pp_kind` applies the packed payload printer to the payload alone, omitting
origin and events. It exists for a boundary that must not emit provenance — a
wire response, a user-facing message, a log a third party reads — because `pp`
is a developer diagnostic and is also what `Printexc.to_string` produces for
these exceptions. Without it such a boundary would have to either send its own
source's frames outward or re-derive a payload printer that the packed value
already carries.

### Printexc integration

The printer is registered once, eagerly, when the module is initialized:

```ocaml
let printer = function
  | E packed -> Some (Format.asprintf "%a" pp packed)
  | _ -> None

let () = Printexc.register_printer printer
```

Eager registration avoids a publication race: a lazily installed printer guarded
by a compare-and-set flag can be observed as installed before
`Printexc.register_printer` has taken effect, so a concurrent caller could
render an exception without its printer. Registration is cheap, has no
dependency on threads, is portable to OCaml 4.12 and both JavaScript backends,
and the printer only matches the library's own private exception constructor.

Because `raise_error` and the failing branch of `or_raise` record `Raise`
through `add_event ~pp_error`, the matching monitor observation can render the
complete error, and:

```ocaml
Printexc.to_string exn
```

and the default uncaught-exception reporter print the structured error rather
than `Err_trace.Exn.E(_)`.

Raising does not itself write to stderr. Automatic printing inside a library
would duplicate reports when callers catch, translate, retry, or log the same
exception. Printing occurs when the exception is uncaught or when a caller
explicitly invokes `Printexc.to_string`, `Err_trace.Exn.pp`, or a logger.

Because registration makes `Printexc.to_string` render the full diagnostic,
code that catches `Exn.E` at an outward-facing boundary matches the constructor
and renders the packed value with `Exn.pp_kind` rather than converting the
exception to a string.

### Exception backtrace versus error trace

The exception runtime may add its own raise-to-catch backtrace. That is distinct
from the error's stored detection origin and semantic event trail:

```text
typed error trace:  detected -> mapped -> filtered/imported -> raised
exception trace:    raise_error -> exception catcher / uncaught handler
```

Both are useful. The registered exception printer renders the typed error trace;
the runtime's uncaught handler may additionally render the exception backtrace
when runtime backtrace recording is enabled.

## Format printer contract

Every public data type has a printer, and every printer is self-contained.

- A printer that opens a `Format` box must close that same box.
- A printer must never close a box opened by its caller.
- A caller must not need to open a box to make a printer valid.
- Literal `[` and `]` are printed only when they are part of the data's syntax;
  they are unrelated to `Format`'s `@[...@]` box notation.
- Printers do not flush the formatter.
- Printers do not change margin, maximum indentation, or global formatter state.

The standard shape is:

```ocaml
let pp ppf value =
  Format.fprintf ppf "@[<v>...@]"
```

The `@[<v>` and `@]` are balanced inside the same function. Nested printers may
open their own boxes independently.

The printer inventory is `Source.pp`, `Source.pp_pos`, `Stack.pp`, `Origin.pp`,
`Action.pp`, `Action.Set.pp`, `Event.pp`, `Error.pp`, `Config.pp`,
`Config.pp_backtrace`, `Config.pp_limit`, `Config.pp_make_error`,
`Config.pp_of_strings_error`, `Observation.pp`, `Monitor.pp`,
`Monitor.pp_callback`, `Exn.pp`, `Exn.pp_kind`, and the top-level `Err_trace.pp` for
`('a, 'e) t`.
Function values have no inspectable content, so `Monitor.pp_callback` renders
the opaque marker `<callback>` and `Monitor.pp` renders only the handle's
observable `installed`/`removed` state. `Action.Set.pp` renders `off` for the
empty set.

`Error.pp` renders approximately:

```text
unknown node n17
detected at:
  graph.ml:41:8-29
trace:
  mapped at decode.ml:88:2-54
  exported at cli.ml:17:4-31
  raised at command.ml:52:6-40
2 trace events not retained
```

If origin or events are absent, their sections are omitted. If stack capture was
requested but produced no symbolizable frames — a JavaScript backend, or a
native binary built without `-g` — the stack printer emits the concise notice
`stack unavailable`; a truncated external stack ends with `[truncated]`.
Printing uses stored data and does not consult the current configuration:
changing runtime flags after an error was built cannot hide or invent its
history.

An optional `Fmt` adapter may provide aliases/combinators, but the base API uses
the standard `Format.formatter -> value -> unit` shape.

## Typical use cases

### Linear propagation

```ocaml
open Err_trace.Syntax

let load path =
  let* bytes = read_file path in
  let* json = parse_json bytes in
  decode json
```

Propagation adds no event. Only semantic transformations do.

### Typed subsystem context

```ocaml
type error =
  [ `Read of Reader.error
  | `Decode of Decoder.error
  ]

let load path =
  let open Err_trace.Syntax in
  let* bytes =
    Reader.read path
    |> Err_trace.map_error ~pos:__POS__ (fun error -> `Read error)
  in
  Decoder.decode bytes
  |> Err_trace.map_error ~pos:__POS__ (fun error -> `Decode error)
```

The variant carries machine-readable context. The trace carries where each
wrapping occurred. Adding `~pp_error:pp_error` supplies the destination domain's
printer to monitors observing that `Map`.

### Lazy conversion from `None`

```ocaml
let require_field name value =
  Err_trace.map_none ~pos:__POS__ ~error:(fun () -> `Missing_field name) value
```

The error thunk runs only for `None`. Use eager `of_option` when the payload is
already available and cheap; use `map_none` when constructing it allocates, may
raise, has effects, or depends on failure-only data.

### Logging monitor

```ocaml
let error_monitor =
  Err_trace.Monitor.install (fun observation ->
    Logs.err (fun message ->
      message "%a" Err_trace.Observation.pp observation))

let stop_error_logging () =
  ignore (Err_trace.Monitor.remove error_monitor : bool)
```

The `Logs` dependency belongs to this adapter, not to `Err_trace`. The callback runs
synchronously, so a slow sink should instead receive a bounded queued snapshot.
With `max_events = 0`, this monitor still sees enabled actions even though
errors retain no event history. Observations produced by calls that passed
`~pp_error` render the full typed error; the others render bounded metadata.

### Cheap production mode

```ocaml
let () = Err_trace.Config.set Err_trace.Config.deterministic
```

Typed failures still work normally. The boundary trail is kept and no automatic
stack is captured. This is also the policy in force at program start, so the
call is only needed to restore it. `Err_trace.Config.fast` is cheaper still but
disables the whole trail, so an error that crosses several domains records none
of those boundaries.

### Debug mode

```ocaml
let () = Err_trace.Config.set Err_trace.Config.debug
```

Every semantic action is retained up to the event bound, and enabled events may
capture call stacks.

### Explicit source positions without stacks

```ocaml
let configure () =
  match
    Err_trace.Config.make ~actions:Err_trace.Action.Set.all ~backtrace:Err_trace.Config.Never
      ~max_events:32 ~max_frames:0 ~max_external_bytes:16384
  with
  | Ok config -> Err_trace.Config.set config
  | Error error ->
      Format.eprintf "invalid error tracing configuration: %a@."
        (Err_trace.Error.pp Err_trace.Config.pp_make_error) error

let validate value = Err_trace.guard ~pos:__POS__ ~error:`Invalid (is_valid value)
```

This mode yields deterministic, low-cost locations and is particularly suitable
for JavaScript and inline expect tests. The configuration failure is itself an
`Err_trace.t`, so it can be matched exhaustively instead of parsed from a string.

### Stack-safe traversal

```ocaml
let decode_all values = Err_trace.List.map decode_one values
```

Traversal is left-to-right, stops at the first error, preserves that error
unchanged, and is tail-recursive.

### Printable exception boundary

```ocaml
let decode_exn input = decode input |> Err_trace.or_raise ~pos:__POS__ ~pp_error
```

If caught:

```ocaml
try decode_exn input with
| exn -> Format.eprintf "%s@." (Printexc.to_string exn)
```

The message contains the payload and stored error trace. No open-coded
`failwith (Format.asprintf ...)` is required.

### Exception export without raising

```ocaml
let submit_to_exception_api input =
  decode input |> Err_trace.export_exn ~pos:__POS__ ~pp_error
```

This returns `('a, exn) result`. Its failure is a printable `Err_trace.Exn.E`
containing the error wrapper with an `Export` event; no exception is raised by
the adapter.

### Independent validation accumulation

Monadic bind short-circuits. A validator that needs every independent problem
states this explicitly:

```ocaml
val validate_all :
  Input.t -> (unit, validation_error Err_trace.Accum.errors) Err_trace.t
```

`Err_trace.Accum.map`, `iter`, `all`, and `both` run every independent item and retain
each failure wrapper. `Accum.lift` turns one ordinary result into a one-element
batch, so a mostly accumulating chain can include a sequential step.
`Accum.fold_errors combine` crosses in the other direction: a function may
accumulate internally and collapse the wrappers into a payload in its existing
published domain. The collapse retains the first failure's origin and event
trail and records no `Map` event.

Because every item runs, so does its work. A size or cost ceiling on untrusted
input must be checked before entering an accumulating traversal; accumulation
belongs only in the bounded portion after that gate. None of these operations
changes `Err_trace.bind` semantics.

## Framework interoperability

### General rule

Frameworks polymorphic in their error type can usually consume `Err_trace.t` directly,
because it uses ordinary `Ok` and `Error` constructors. Conversion is required
when a framework fixes its error type, uses exceptions, serializes values, or
expects a human-readable diagnostic.

The questions each conversion answers are:

- whether the typed payload survives;
- whether the original origin and events survive;
- whether an `Import` or `Export` event is added;
- whether the conversion is lossy;
- which exceptions/cancellation signals remain outside the expected-error model.

### Conversion summary

| Representation | Into `Err_trace` | Out of `Err_trace` | Loss |
|---|---|---|---|
| Generic `Stdlib.result` with wrapper error | None | None | None |
| Bare `('a, 'e) result` | Wrap at `Import` boundary | Unwrap after `Export` | Export loses trace |
| Exception API | `protect` selected exceptions | `to_exn`, `export_exn`, or `or_raise` | None when structured exception retained |
| Jane Street `Or_error.t` | Store `Base.Error.t` in a typed variant | Render/build `Base.Error.t` | Typed row normally erased on export |
| Async `Or_error.t Deferred.t` | Map inside `Deferred.t` | Map inside `Deferred.t` | Same as `Or_error` |
| `Lwt_result.t` | Map error inside `Lwt.t` | Compatible when error is `Err_trace.Error.t` | None if wrapper retained |
| Rresult `R.t` | Direct result composition or named import | Direct composition or named export | None unless wrapper is dropped |
| Cmdliner term result | Rarely imported | Convert to `` `Msg string `` | Typed payload/trace rendered then lost |
| Mirage abstract error | Implement abstract type as `domain_error Err_trace.Error.t` | Usually none | None |
| Compiler diagnostic | `Location.t` becomes a `Source.t` in `Error.make_at` | Translate at reporting boundary | Domain-specific |
| Octez `tzresult` | Store complete trace as typed variant | Inject registered error | Depends on encoding |
| HTTP/JSON/RPC | Decode stable code to typed variant | Encode safe public error | Never transmit native trace by default |

### Bare standard results

```ocaml
let of_result result = Err_trace.import ~pos:__POS__ Fun.id result
let to_result result = Err_trace.export ~pos:__POS__ result
```

`Err_trace.import` records `Import` and maps the bare error into this domain;
`Err_trace.export` records `Export` and then drops the wrapper. Both are named
rather than inlined: one captures only the import boundary, and the other
deliberately discards trace data. `Err_trace.payload` drops the wrapper without
recording an event.

### Jane Street errors

Import without flattening:

```ocaml
type error = [ `Jane_street of Base.Error.t ]

let of_or_error result =
  result
  |> Stdlib.Result.map_error
       (fun error -> Err_trace.Error.make (`Jane_street error))
  |> Err_trace.mark_error Err_trace.Action.Import
```

Export may render `Err_trace.Error.pp` into `Base.Error.of_string`, or build a
structured S-expression with stable fields. Either erases the compile-time error
row from the resulting `Or_error.t`, so conversion belongs at a boundary.

### Lwt and Async

Keep asynchrony outside the typed result:

```ocaml
('a, 'e) Err_trace.t Lwt.t
('a, 'e) Err_trace.t Async.Deferred.t
```

Map conversions inside the promise/deferred value. Lwt cancellation remains an
Lwt concern, and exceptions routed through an Async monitor remain an Async
concern, unless an application explicitly classifies a particular case as
recoverable.

### CLI and diagnostics

Command frameworks generally consume strings or structured messages. A named
adapter marks `Export`, renders with a domain printer, and drops the wrapper.
Normal user output omits provenance — `Error.kind` with the domain printer, or
`Exn.pp_kind` for a packed exception — while a debug option uses the full
`Error.pp`.

Compiler diagnostics travel in the opposite direction: a `Location.t` is
converted to `Source.of_pos` and installed through `Origin.make` plus
`Error.make_at`, so the imported error keeps the compiler's location instead of
the adapter's own call site.

### Wire formats

Wire errors use stable codes and bounded JSON-compatible details:

```ocaml
module Wire_error = struct
  type t = {
    code : string;
    message : string;
    details : Json.t option;
    trace_id : string option;
  }
end
```

Raw stack text can expose paths, source layout, URLs, and data. It is retained
in server-side diagnostics and correlated through `trace_id`, not sent by
default. Remote stacks remain remote diagnostic data; they are not represented
as the receiver's local origin.

The `message` field is rendered from the domain payload only: with a domain
printer through `Error.kind`, or with `Exn.pp_kind` when the boundary already
holds a packed exception. `Error.pp`, `Exn.pp`, and `Printexc.to_string` all
include provenance and belong in the server-side record instead.

### Where the adapters live

Adapters for Base/`Or_error`, Async, Lwt, Rresult, Cmdliner, Mirage Flow,
compiler diagnostics, Octez, Fmt, Logs, Yojson wire values, js_of_ocaml, and
Melange exist as tests under `test/adapters` and `test`. They are test-only, so
`err_trace` itself has only standard-library runtime dependencies. A binding
that later becomes a shipped library belongs in a separate opam package (for
example, `err_trace-lwt`) whose framework dependency is then unconditional
rather than a test capability.

Octez's error monad is available only through the broad `octez-libs` package,
not as a small standalone error package, so its conformance runs as a dedicated
CI capability rather than as an opam test dependency. Dune's diagnostic modules
informed this library but are comparison-only: they are private implementation
APIs, so they are not dependencies of any adapter.

## JavaScript backends

### Observed runtime behavior

js_of_ocaml and Melange both compile the typed result representation and pure
combinators. Their OCaml `Printexc` compatibility does not provide
native-quality `get_callstack` frames:

- js_of_ocaml's runtime returns an empty raw trace for `get_callstack` and keeps
  JavaScript stacks separately on `Js_error` values;
- Melange's compatibility implementation yields no usable `backtrace_slots`,
  and the value its `get_callstack` returns cannot even be measured with
  `raw_backtrace_length`, while JavaScript exceptions expose `name`, `message`,
  and `stack` through `Js.Exn`.

Therefore `Config.backtrace = Origin | Events` is best effort. An unavailable
stack is not an error-handling failure, and `Stack.pp` renders the
`stack unavailable` notice — see [Stack availability](#stack-availability) for
why that decision goes through `backtrace_slots`. Explicit `~pos:__POS__`
remains portable and deterministic.

### Native JavaScript errors

Backend adapters classify only documented JavaScript errors and convert their
`Error.stack` with:

```ocaml
let origin_of_javascript_stack ~pos runtime stack =
  let stack = Err_trace.Stack.of_external ~runtime ~stack in
  Err_trace.Origin.make ~source:(Err_trace.Source.of_pos pos) ~stack ()
```

The imported error is then built with `Err_trace.Error.make_at` and marked with
`Err_trace.mark_error ~pos Err_trace.Action.Catch`, so the boundary is recorded without the
library recapturing an OCaml call stack.

For js_of_ocaml, catch `Js_error.Exn`, inspect `name`, `message`, and `stack`,
and re-raise unclassified errors with `Js_error.raise_`. For Melange, catch an
OCaml `exn`, inspect it through `Js.Exn.asJsExn`, and re-raise when
classification returns no expected domain error.

JavaScript may throw any value. Adapters must not recursively stringify
arbitrary objects or depend on unstable internal conversion APIs. A native
JavaScript shim should normalize a foreign API that throws non-`Error` values.

`to_exn` and `export_exn` construct OCaml `exn` values even when compiled to
JavaScript. They are appropriate for OCaml-facing callback APIs, but are not a
public native JavaScript error representation. A backend-specific export to
JavaScript must first record `Export`, render the bounded safe message — from
the payload alone, through the domain printer or `Exn.pp_kind` — then construct
a genuine JavaScript `Error`; it may attach a stable public code or trace
identifier, but not the OCaml wrapper. Expected failures should normally use the
outcome object below instead of throwing.

### Public JavaScript outcome

Compiler-specific OCaml representations are not a JavaScript API. Export a plain
discriminated object:

```javascript
{ ok: true, value: value }

{
  ok: false,
  error: {
    code: "unknown-node",
    message: "unknown node n17",
    details: { node: "n17" },
    traceId: null
  }
}
```

Expected domain errors return `ok: false`. Programmer errors and invariant
failures throw genuine JavaScript `Error` values.

### Promises

Promise rejection reasons are arbitrary and backend bindings commonly expose
them as opaque values. The portable public contract is:

```text
Promise<JsOutcome<T>>

resolve { ok: true, value }      expected success
resolve { ok: false, error }     expected domain failure
reject JavaScript Error          programmer error, transport failure,
                                 cancellation, or unclassified rejection
```

Foreign Promises should normalize only documented expected rejections:

```javascript
async function settleExpected(promise) {
  try {
    return { ok: true, value: await promise };
  } catch (reason) {
    if (isExpectedForeignError(reason)) {
      return { ok: false, error: toPublicError(reason) };
    }
    throw reason;
  }
}
```

Do not reject with an OCaml `Err_trace.Error.t`; handwritten JavaScript cannot safely
inspect it. Do not translate every rejection into a domain error; cancellation
and unexpected failures must retain their native behavior.

### Optional JavaScript stack capture

`Err_trace.fail` does not allocate `new Error()` under JavaScript. Doing so on every
failure is expensive and requires backend-specific code. A future optional
adapter may capture `new Error().stack` and call `Error.make_at`, controlled by
the same backtrace policy.

An origin-provider virtual library is another possible extension. Explicit
source positions and imported JavaScript stacks already cover deterministic and
boundary diagnostics without coupling the package to either compiler.

### Melange build arrangement

Melange support is a separate package, `err_trace-melange`, so that the native
`err_trace` package needs no `melange` dependency. Its library lives in
`melange/src`, which copies `err_trace.ml`/`err_trace.mli` and builds the same sources with
`(modes byte native melange)`. The stanza is enabled only when
`ERR_TRACE_MELANGE=true` (set by the `err_trace-melange` opam build) or
`ERR_TRACE_TEST_MELANGE=true` (the tests); the ordinary `src/dune` stanza is
unaffected. Normal builds therefore never schedule `melc` rules. `make test-melange-optin` enforces exactly that: with the
variable unset it asserts that `dune rules @all` schedules no `melc` rule and
that `dune build @all` succeeds, and when `melc` is on `PATH` it asserts that
the opt-in configuration does schedule `melc` rules and builds `@melange-test`.
It runs in every core CI job, including those without Melange installed.

### Monitors under JavaScript

The monitor API applies to both backends because it uses OCaml callbacks,
`Stdlib.Atomic`, and the same event values as native code. In the usual single
JavaScript event loop, synchronous dispatch and snapshot removal have the same
observable semantics without parallel callbacks. A callback may call `console`
through a backend adapter or enqueue a plain JavaScript log record, but it must
not await a Promise during dispatch. It should copy or render what it needs
before returning; an `Observation.t` is an OCaml value and must not be exported
as a public JavaScript object.

Callback exceptions are caught and handled by the same removal/`on_error`
policy. A JavaScript logger that throws is therefore disabled without replacing
an expected result, an exported exception, or an already-active raise.

## Tests and checks

The test suite covers every public value and constructor along with the stated
failure, ordering, bounding, concurrency, and backend behavior, so the
statements made above are checked rather than merely asserted.

`make build`, `make test-core`, and `make fmt-check` need only Dune, the OCaml
formatter, and `ppx_expect`. Every other suite is a focused capability target
that installs its own dependencies.

### Inline expect tests

`test/core.ml` holds the `ppx_expect` suite and runs under
`(inline_tests (modes byte native))`, so both the bytecode and the native
runtime are exercised. The library itself remains PPX-free.

Expect tests install a deterministic configuration (normally
`backtrace = Never`) with a `Fun.protect` helper that restores the previous
process configuration, and use fixed `Source.pos` literals so goldens are
stable. The cases are:

- configuration presets, parsing, and portable bounds;
- configuration errors dog-food `Err_trace.t`, and every public data type prints;
- success paths and ordinary propagation add no trace data;
- mapping is failure-only and retains provenance;
- `Error.map_kind` records its own typed conversion point;
- `pp_error` stays polymorphic across unrelated and composable variant domains;
- a smaller event bound immediately trims all excess history;
- `guard` and `protect` record only selected failures;
- `protect` uses the configuration captured at the catch point;
- `Origin` policy captures a stack when `fail` has no explicit source;
- external and unavailable stacks render bounded diagnostics;
- error and exception printers are structured and composable, and `Exn.pp_kind`
  renders the payload alone from an error that has both an origin and events;
- exception export does not raise, and raising records only `Raise`;
- monitor dispatch uses installation-order snapshots;
- monitor filters, zero retention, and failure containment;
- callback failure invokes its own hook and cannot replace the result;
- observations print metadata or the complete typed error;
- traversals preserve order, stop at failure, and are stack safe (100,000
  elements without `Stack_overflow`).

Native stack text never appears in a golden. Frame names, inlining, paths, and
JavaScript engine formatting are not stable, so provenance tests assert
structural properties (`Origin.source`/`Origin.stack` presence, event names,
counts) and printer tests assert only the library's own framing. Rendered native
stack text is checked by properties only: no empty line, no `Raised`/`Called`
runtime wording, and a first frame outside `err_trace.ml`.

### Format composition tests

Printers must prove that they balance their own boxes. The printer test renders
an error and a packed exception between content owned by the caller, at a narrow
margin set with `Format.pp_set_margin`, and asserts that the caller's trailing
content returns to the caller's indentation. A leaked or over-closed box moves
the golden.

### Monitor and concurrency tests

The expect suite covers installation order, per-monitor action filters versus
`Config.actions`, `max_events = 0` with live callbacks and an incrementing
`dropped_events`, removal returning `true` once and `false` afterwards,
install/remove during a callback affecting only the next dispatch, callback
failure removing only that monitor and invoking `on_error` (with `None` for the
stack under `backtrace = Never`), a contained `on_error` failure, and the
difference between metadata-only and fully printable observations. Every test
installs monitors under `Fun.protect` so the global registry cannot leak state
between inline tests.

`test/multicore.ml` is a native OCaml 5 executable (`enabled_if ocaml_version >=
5.0`, `make test-multicore`). It installs monitors from several domains,
dispatches thousands of concurrent `Detect` events, asserts the exact expected
callback count, then removes monitors concurrently and asserts that removal is
observed exactly once per handle and that later events reach no callback.

### Examples and cram tests

`examples/poly_errors.ml` is a complete program with nested polymorphic-variant
error domains, a shared base domain, and one installed monitor that logs both a
`Detect` and a `Map` boundary through `Observation.pp` with the printer of the
domain at that boundary. `test/examples` runs it as a cram test under bytecode,
native code, js_of_ocaml, and Melange, which keeps rendered output identical
across backends.

### Adapter capabilities

Each adapter is a small program that exercises both directions and is executed
in bytecode and native form:

| Target | Package | Conformance case |
|---|---|---|
| `make test-base-async` | `base`, `async_kernel` | import `Base.Error.t`; lossy rendered export; map inside `Deferred.t` |
| `make test-lwt` | `lwt` | map inside `Lwt.t`; preserve cancellation |
| `make test-rresult` | `rresult` | direct wrapped result and named lossy export |
| `make test-cmdliner` | `cmdliner` | exported `` `Msg `` contains stable user text, not a raw stack |
| `make test-mirage` | `mirage-flow` | wrapper satisfies the abstract error position |
| `make test-compiler-locations` | `compiler-libs.common` | `Location.t` import and reporting-boundary export |
| `make test-octez` | `octez-libs` | complete trace import and registered-error export |
| `make test-fmt-logs-yojson` | `fmt`, `logs`, `yojson` | printer composes without leaking boxes; monitor logs one boundary; safe bounded wire export |
| `make test-js` | `js_of_ocaml` | native `Error.stack`, outcome object, Promise behavior |
| `make test-melange` | `melange` | native exception stack, outcome object, Promise behavior |

Each adapter target is gated by its own `ERR_TRACE_TEST_*` environment variable
so an ordinary build never requires those packages. `test-octez` reports a skip
and succeeds when `octez-libs` is absent, because it also runs where that
closure is not installed. `test-melange` reports a skip and fails, because it is
invoked only from the JavaScript environment that is expected to provide
`melc`.

The JavaScript consumer tests verify that exported success and expected failure
use plain outcome objects, that a native JavaScript `Error.stack` becomes an
external origin, that unclassified throws escape, that expected Promise failures
resolve as outcomes while unknown rejections remain rejections, that raw OCaml
representations do not cross the public boundary, that OCaml exception export
remains printable inside compiled OCaml while native JavaScript export produces
a genuine `Error`, and that normal responses omit debug stacks.

### Performance tests

Expect tests cannot prove the performance contract. `bench/allocation.ml`
(`make bench`) measures allocated bytes per operation for:

- success paths under the `fast`, `deterministic`, `with_stacks`, and `debug` presets;
- failure construction with backtraces off versus `Origin`;
- `map_error` with the action disabled, with source-only tracing, and in
  event-stack mode;
- trace overflow at `max_events`;
- external-stack truncation;
- exception packing and rendering;
- dispatch to three monitors with `max_events = 0`.

Exact byte counts are diagnostic rather than portable: they can change with the
OCaml compiler, word size, optimization decisions, runtime, and instrumentation.
`bench/allocation_invariants.ml` (`make bench-check`, included in `make ci`)
therefore enforces only relational contracts that should hold across the matrix:
successful paths are policy-independent, and enabling sources, stacks, or
monitors costs more than their disabled forms.

For attribution rather than regression detection, use Memtrace and
`memtrace-viewer` on a representative native workload. `Gc.allocated_bytes` is
the right low-noise counter for repeatable total-allocation comparisons;
Memtrace explains the allocation sites and retained paths. Wall-clock tools such
as `perf stat`, Core_bench, or Hyperfine answer a different question and need a
pinned quiet host, warmup, repeated samples, and statistical thresholds rather
than byte-count assertions. JavaScript allocation behavior needs a separate
baseline and the host runtime's tools, such as the Chrome or Node heap profiler
and Node's `--trace-gc`; native byte counts are not a cross-backend budget.

## Packaging

The runtime package has no third-party dependencies:

```opam
depends: [
  "ocaml" {>= "4.12.0"}
  "dune" {>= "3.15"}
  "odoc" {with-doc}
  "ppx_expect" {with-test}
  "mdx" {with-test}
]
```

The only test-only dependencies are `ppx_expect` and `mdx`. The adapter and
JavaScript test dependencies (`base`, `async_kernel`, `lwt`, `rresult`,
`cmdliner`, `mirage-flow`, `fmt`, `logs`, `yojson`, `js_of_ocaml-compiler`,
`js_of_ocaml-ppx`) are not in `depends`; the Makefile targets that need them
install them.

`Atomic` is the newest standard-library API the implementation uses, and it
arrived in OCaml 4.12, which sets the compiler floor. `compiler-libs.common`
ships with the selected compiler and is linked only by its test executable, so
it needs no opam entry.

Two capabilities are deliberately absent from `depends`:

- Melange does not support the 4.12 floor, so it lives in the separate
  `err_trace-melange` package, and `err_trace`'s `run-test` command does not
  enable Melange rules; it is exercised in its own JavaScript environment;
- `octez-libs` would impose an outsized dependency closure and platform
  restrictions on ordinary opam users, so Octez conformance stays a CI
  capability (`make test-octez`) rather than a published auxiliary package.

CI builds and runs
`make build test-core test-melange-optin bench-check fmt-check` across the OCaml
matrix: 4.12.1 and 4.13.1 on 64-bit targets, 4.14.3 on both 64- and 32-bit
targets, and 5.2.1 through 5.5.0 on 64-bit targets. It adds
`make test-multicore` on OCaml 5 and runs the dependency-heavy adapter,
JavaScript, and Octez suites in dedicated cached devcontainers. The 4.12
developer image pins `pp` to 1.2.0 and `yojson` to 2.2.2 because its compatible
`ocaml-lsp-server.1.9.0` lacks upper bounds but is incompatible with the later
breaking `pp.2.0.0` and `yojson.3.0.0` releases; these are developer-tool
constraints, not runtime dependencies.

## Comparison with other approaches

### Bare `Stdlib.Result`

This is sufficient where detection origin and mapping history have no diagnostic
value. It cannot enforce provenance preservation across semantic wrapping.

### Jane Street `Or_error`

`Or_error` offers rich diagnostics, contextual tagging, exception conversion, and
applicative accumulation. It also gives every failure the same `Base.Error.t`, so
an API no longer exposes a closed set of recoverable domain errors. It is a good
boundary representation but not the default model here.

### Global extensible error registry

A registered global universe works for systems that serialize errors across many
packages. It weakens exhaustiveness and adds registration/encoding machinery.
Local typed variants plus explicit adapters are smaller.

### Full backtrace at every map

This maximizes diagnostics but makes mapping expensive, duplicates large stacks,
and behaves inconsistently across JavaScript engines. `Config.backtrace = Events`
supports it for debugging without imposing it as the default.

### String tags

String tags are easy to append but are not machine-readable or exhaustively
matched. Typed payload wrapping plus `Map` events separates semantic context from
diagnostic location.

### Retaining the payload printer in the error

Storing an existential printer inside `Error.t` would make every error
self-printing. It also keeps a closure alive for the lifetime of the error,
potentially retaining large or sensitive captured data, and it forces every
domain conversion to decide which printer wins. Passing `pp_error` per call
gives monitors and boundaries the same rendering ability with no retention.

### Automatically log on raise

Automatic logging creates duplicate reports when exceptions are caught or
translated. A registered printer makes exceptions printable without coupling the
library to output policy. Applications that intentionally want event-level
logging install a removable monitor and choose its action filter explicitly;
the library still selects no sink and writes nothing by itself.

## References

- Jane Street Base
  [`Error`](https://ocaml.org/p/base/latest/doc/base/Base/Error/index.html) and
  [`Or_error`](https://ocaml.org/p/base/latest/doc/base/Base/Or_error/index.html)
- Jane Street Async
  [`Monitor`](https://ocaml.org/p/async_kernel/latest/doc/async_kernel/Async_kernel/Monitor/index.html)
- Dune
  [`User_error`](https://github.com/ocaml/dune/blob/main/otherlibs/stdune/src/user_error.ml),
  [`Code_error`](https://github.com/ocaml/dune/blob/main/otherlibs/stdune/src/code_error.ml),
  and
  [`User_message`](https://github.com/ocaml/dune/blob/main/otherlibs/stdune/src/user_message.ml)
- Octez
  [error monad](https://octez.tezos.com/docs/developer/error_monad.html) and
  [`tzresult` traces](https://octez.tezos.com/docs/developer/error_monad_p2_tzresult.html),
  plus the official opam
  [`octez-libs` package](https://opam.ocaml.org/packages/octez-libs/)
- OCaml compiler-libs
  [`Location`](https://ocaml.org/manual/5.1/api/compilerlibref/Location.html)
- Mirage
  [error conventions](https://mirage.io/docs/mirage-3.0-errors)
- Rresult
  [design and API](https://erratique.ch/software/rresult/doc/Rresult/index.html)
- js_of_ocaml
  [error handling](https://ocsigen.org/js_of_ocaml/latest/js_of_ocaml/errors.html),
  [`Js_error`](https://ocsigen.org/js_of_ocaml/latest/api/js_of_ocaml/Js_of_ocaml/Js/Js_error/index.html),
  and
  [API index](https://ocsigen.org/js_of_ocaml/latest/js_of_ocaml/api.html)
- Melange
  [`Js.Exn`](https://melange.re/unstable/api/ml/melange/Js-Exn.html),
  [`Js.Promise`](https://melange.re/unstable/api/ml/melange/Js-Promise.html),
  [`Stdlib.Atomic`](https://melange.re/v4.0.0/api/ml/melange/Stdlib/Atomic/index.html),
  and
  [exception representation](https://melange.re/blog/posts/melange-4-is-here)
