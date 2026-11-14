(** Typed recoverable errors with optional, bounded diagnostic provenance. *)

module Source : sig
  type pos = string * int * int * int
  (** The shape of OCaml's [__POS__] value. *)

  type t
  (** A backend-independent source coordinate. *)

  val of_pos : pos -> t
  (** Build a source coordinate from OCaml's [__POS__] value. *)

  val pp_pos : Format.formatter -> pos -> unit
  (** Print an unwrapped [__POS__] value. *)

  val pp : Format.formatter -> t -> unit
  (** Print [file:line:start-end]. *)
end

module Stack : sig
  type t
  (** A native raw backtrace or a bounded stack imported from another runtime. *)

  val of_raw_backtrace : Printexc.raw_backtrace -> t
  (** Wrap a native raw backtrace. *)

  val of_external : runtime:string -> stack:string -> t
  (** Import a foreign runtime's stack string, bounded by {!Err.Config.max_external_bytes}.

      This serves one narrow case: a JavaScript host that hands your program its own stack, which an adapter imports
      rather than captures. A library or a command-line program never calls it, and can ignore this constructor,
      {!is_available}, and the [max_external_bytes] limit entirely. *)

  val is_available : t -> bool
  (** Whether this stack contains available diagnostic data. *)

  val to_raw_backtrace : t -> Printexc.raw_backtrace option
  (** Return a native backtrace when this is not an external stack. *)

  val pp : Format.formatter -> t -> unit
  (** Render the stack. *)
end

module Origin : sig
  type t
  (** An explicit source location, a stack, or both. *)

  (** [None] when neither optional component is supplied. *)
  val make : ?source:Source.t -> ?stack:Stack.t -> unit -> t option
  (** Construct no origin when both arguments are absent. *)

  val source : t -> Source.t option
  (** Extract the explicit source coordinate. *)

  val stack : t -> Stack.t option
  (** Extract the captured or imported stack. *)

  val pp : Format.formatter -> t -> unit
  (** Render available origin information. *)
end

module Action : sig
  (** A semantic error transition, rather than an ordinary propagation step. *)
  type t =
    | Detect
    | Map
    | Filter
    | Catch
    | Raise
    | Import
    | Export  (** [Detect] creates a failure; other constructors describe semantic boundaries. *)

  val pp : Format.formatter -> t -> unit
  (** Render the action name. *)

  module Set : sig
    type action = t
    (** The action type accepted by this set. *)

    type t
    (** An immutable action selection. *)

    val empty : t
    (** Select no actions. *)

    val all : t
    (** Select all actions. *)

    val boundaries : t
    (** Select every action except [Detect]: the transitions where an error crosses a boundary, as opposed to the point
        at which it is created. This is the spelling [boundaries] accepted by {!Err.Config.of_strings}. *)

    val of_list : action list -> t
    (** Construct a set, ignoring duplicates. *)

    val mem : action -> t -> bool
    (** Test action membership. *)

    val pp : Format.formatter -> t -> unit
    (** Render selected actions, or [off] for the empty set. *)
  end
end

module Event : sig
  (** A selected semantic transition and its optional boundary origin. *)
  type t
  (** An action and its optional event-boundary origin. *)

  val action : t -> Action.t
  (** Return the event action. *)

  val origin : t -> Origin.t option
  (** Return the event origin. *)

  val pp : Format.formatter -> t -> unit
  (** Render the event. *)
end

module Error : sig
  (** A typed payload plus immutable diagnostic provenance. *)
  type +'e t
  (** A typed payload plus immutable origin and bounded events. *)

  val make : ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'e -> unit) -> 'e -> 'e t
  (** Create a detected error under the current policy. [pp_error] lets matching synchronous monitors render the
      complete error and is not retained by the error. *)

  val make_at : origin:Origin.t option -> 'e -> 'e t
  (** Create an imported error without recapturing its origin. *)

  val kind : 'e t -> 'e
  (** Return the domain payload. *)

  val origin : 'e t -> Origin.t option
  (** Return the non-evictable detection origin. *)

  val events : 'e t -> Event.t list
  (** Return retained events from oldest to newest. *)

  val dropped_events : 'e t -> int
  (** Return the saturating count of discarded events. *)

  val map_kind : ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'b -> unit) -> ('a -> 'b) -> 'a t -> 'b t
  (** Change the payload, preserve its detection origin, and append [Map] at the conversion point when selected.
      [pp_error] describes the new payload for matching monitors. *)

  val pp : (Format.formatter -> 'e -> unit) -> Format.formatter -> 'e t -> unit
  (** Render payload, origin, events, and dropped-event count. *)

  val pp_kind : (Format.formatter -> 'e -> unit) -> Format.formatter -> 'e t -> unit
  (** Render only the domain payload, omitting origin and events. Use at a boundary that must not emit provenance -- a
      wire response, a user-facing message, a log read by a third party -- where {!pp} would be too much. This is
      {!Err.Exn.pp_kind} for the ordinary error wrapper. *)
end

type ('a, 'e) t = ('a, 'e Error.t) result
(** A result whose error branch retains a typed {!Error.t} wrapper. *)

module Config : sig
  (** Automatic native stack capture policy. *)
  type backtrace =
    | Never
    | Origin
    | Events
        (** [Never] captures no automatic stack, [Origin] only detection/catch, and [Events] captures every enabled
            event. *)

  type t
  (** An immutable validated trace policy. *)

  type limit = [ `Max_events | `Max_frames | `Max_external_bytes ]
  (** A configurable bounded resource. *)

  type make_error = [ `Negative_limit of limit * int | `Limit_too_large of limit * int ]
  (** Typed validation failures returned by {!make}. *)

  type of_strings_error =
    [ make_error
    | `Invalid_limit of limit * string
    | `Unknown_backtrace_mode of string
    | `Unknown_trace_action of string
    | `Empty_trace_action of int  (** 1-based position of an empty item in a comma-separated list *) ]
  (** Typed parsing and validation failures returned by {!of_strings}. *)

  val pp_backtrace : Format.formatter -> backtrace -> unit
  (** Render a backtrace policy as the spelling {!of_strings} accepts, so a logged policy can be parsed back. [Never]
      renders as [off], matching the [trace] axis's name for the same idea. *)

  val pp_limit : Format.formatter -> limit -> unit
  (** Render a configuration limit name. *)

  val pp_make_error : Format.formatter -> make_error -> unit
  (** Render a configuration validation failure. *)

  val pp_of_strings_error : Format.formatter -> of_strings_error -> unit
  (** Render a configuration parsing or validation failure. *)

  (** Validate limits and construct a trace policy. Limits must be non-negative and representable on a 32-bit runtime.
      Failures use the library's own typed error wrapper. *)
  val make :
    actions:Action.Set.t ->
    backtrace:backtrace ->
    max_events:int ->
    max_frames:int ->
    max_external_bytes:int ->
    (t, make_error Error.t) result
  (** Validate all limits and create a policy. The return type is [(t, make_error) Err.t]. *)

  val fast : t
  (** The cheapest policy: no semantic events at all, and no stacks. It disables the {e whole} event trail, not just
      stack capture, so an error that crosses several domains records none of those boundaries. A detection origin still
      survives wherever the call site supplied [~pos]; without [~pos] such an error carries no provenance whatever.

      This is not the recommended production preset despite its name. For production use {!deterministic}, which drops
      the same stacks but keeps the trail. *)

  val deterministic : t
  (** Production preset: keep the boundary event trail, capture no automatic stack. Diagnostics are then identical on
      native OCaml, bytecode, js_of_ocaml, and Melange wherever call sites supply [~pos:__POS__].

      The two sources of nondeterminism are independent: {!actions} decides how much semantic trail is kept, and
      {!val-backtrace} decides whether call stacks are captured. The [fast]/[default]/[debug] ladder bundles them; this
      preset is the useful off-diagonal combination. *)

  val default : t
  (** Boundary-event preset with origin stacks. This is the policy in force before any call to {!set}. *)

  val debug : t
  (** All-event preset with event stacks. *)

  (** Process-wide atomic configuration. Change it during startup where possible. *)
  val get : unit -> t
  (** Read the current process-wide policy atomically. *)

  val set : t -> unit
  (** Replace the process-wide policy atomically. *)

  val with_config : t -> (unit -> 'a) -> 'a
  (** Install a policy, run the function, and restore the previous policy even if it raises.

      The configuration is process-wide, so this is {b not} a thread- or domain-scoped setter: concurrent code observes
      the temporary policy, and overlapping rather than properly nested uses restore in an unspecified order. It is
      intended for tests and for single-threaded startup sequences. *)

  val actions : t -> Action.Set.t
  (** Return selected actions. *)

  val backtrace : t -> backtrace
  (** Return the stack policy. *)

  val max_events : t -> int
  (** Return the retained-event bound. *)

  val max_frames : t -> int
  (** Return the native-frame bound. *)

  val max_external_bytes : t -> int
  (** Return the imported-stack byte bound. *)

  val pp : Format.formatter -> t -> unit
  (** Render the complete validated policy. *)

  (** Parse application-supplied configuration strings without reading the environment. [trace] accepts [off],
      [boundaries], [all], or comma-separated action names; [backtrace] accepts [off] (or its constructor spelling
      [never]), [origin], or [events]. Surrounding whitespace is ignored, so the output of {!pp}, {!pp_backtrace}, and
      {!Err.Action.Set.pp} parses back to the value that produced it. *)
  val of_strings :
    trace:string option ->
    backtrace:string option ->
    max_events:string option ->
    max_frames:string option ->
    max_external_bytes:string option ->
    (t, of_strings_error Error.t) result
  (** Parse host-provided settings without reading environment variables. The return type is
      [(t, of_strings_error) Err.t]. *)
end

module Observation : sig
  (** The immutable snapshot passed synchronously to a monitor. *)
  type t
  (** An immutable monitor-dispatch snapshot. *)

  val event : t -> Event.t
  (** Return the event being dispatched. *)

  val error_origin : t -> Origin.t option
  (** Return the error detection origin. *)

  val retained_events : t -> Event.t list
  (** Return events retained after insertion. *)

  val dropped_events : t -> int
  (** Return the snapshot's dropped-event count. *)

  val pp : Format.formatter -> t -> unit
  (** Print the complete error only when the producing boundary supplied a payload printer; otherwise print event
      metadata. *)
end

module Monitor : sig
  type t
  (** A handle for one installed monitor. Pass it to {!remove} when the monitor is no longer needed. *)

  type callback = Observation.t -> unit
  (** A synchronous callback invoked for each matching enabled event. Callbacks must be short, non-blocking, and must
      not produce further [Err] events. *)

  val install : ?actions:Action.Set.t -> ?on_error:(exn -> Stack.t option -> unit) -> callback -> t
  (** Install [callback] in installation order. [actions] defaults to every action. A callback that raises is removed;
      [on_error] then receives its exception and a stack when the active policy captured one. *)

  val remove : t -> bool
  (** Idempotently remove a monitor. It returns [true] only for the call that changes an installed monitor to removed.
  *)

  val pp : Format.formatter -> t -> unit
  (** Render whether this monitor handle is currently [installed] or [removed]. *)

  val pp_callback : Format.formatter -> callback -> unit
  (** Render an opaque callback marker. *)
end

val pp : (Format.formatter -> 'a -> unit) -> (Format.formatter -> 'e -> unit) -> Format.formatter -> ('a, 'e) t -> unit
(** Render either [Ok] and its value or [Error] and the complete typed error. *)
(* The following operations preserve typed payloads; events occur only on the
   documented error branches. *)

val return : 'a -> ('a, 'e) t
(** Return a successful value without reading tracing configuration. *)

val fail : ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'e -> unit) -> 'e -> ('a, 'e) t
(** Create a detected failure under the active policy. [pp_error] lets matching synchronous monitors render the complete
    error and is not retained by the error. *)

val of_option : ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'e -> unit) -> 'e -> 'a option -> ('a, 'e) t
(** Convert [None] to a detected error; its payload is eager. *)

val map_none :
  ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'e -> unit) -> error:(unit -> 'e) -> 'a option -> ('a, 'e) t
(** Lazily construct an error only for [None]. *)

val guard : ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'e -> unit) -> error:'e -> bool -> (unit, 'e) t
(** Return [Ok ()] for true or a [Filter] failure for false. *)

val map : ('a -> 'b) -> ('a, 'e) t -> ('b, 'e) t
(** Map successes while propagating errors without tracing. *)

val bind : ('a, 'e) t -> ('a -> ('b, 'e) t) -> ('b, 'e) t
(** Sequence successes while propagating errors without tracing. *)

val map_error : ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'f -> unit) -> ('e -> 'f) -> ('a, 'e) t -> ('a, 'f) t
(** Map errors and append [Map] only when selected. [pp_error] describes the mapped domain for matching monitors. *)

val mark_error : ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'e -> unit) -> Action.t -> ('a, 'e) t -> ('a, 'e) t
(** Append a selected semantic action only on errors. *)

val payload : ('a, 'e) t -> ('a, 'e) Stdlib.result
(** Drop the wrapper and keep the typed payload, recording no event. This is the unmarked unwrap, for tests, assertions,
    and rendering. At a boundary the application treats as lossy, use {!export} instead, which marks it. *)

val import :
  ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'f -> unit) -> ('e -> 'f) -> ('a, 'e) Stdlib.result -> ('a, 'f) t
(** Lift a bare result from a third party, mapping its error into this domain. Records [Import] and captures an origin
    under the active policy. No [Detect] event is added: the failure was detected by whoever produced the result. *)

val export : ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'e -> unit) -> ('a, 'e) t -> ('a, 'e) Stdlib.result
(** Record [Export], then drop the wrapper, keeping the typed payload. This is the named helper for a deliberate wrapper
    drop, so the marking is automatic rather than remembered. The payload stays typed rather than rendered: a string is
    [Result.map_error (Format.asprintf "%a" pp_error)] away, and which format to use is the caller's decision. *)

(** {1 Boundaries: exceptions and non-local exits} *)

val protect :
  ?pos:Source.pos ->
  ?pp_error:(Format.formatter -> 'e -> unit) ->
  catch:(exn -> 'e option) ->
  (unit -> 'a) ->
  ('a, 'e) t
(** Convert selected exceptions to [Catch] errors and re-raise others, preserving their original backtrace wherever the
    runtime supports doing so. Propagation is independent of {!val:Config.backtrace}: that policy controls provenance
    retained in typed errors, not the semantics of an unrelated exception crossing this boundary. *)

module Escape : sig
  (** A scoped non-local exit, for the walk that cannot thread a result through every arm.

      A deeply recursive traversal usually cannot be rewritten around {!bind} without rewriting the whole module, so it
      exits through an exception instead. Declaring that exception by hand costs a raiser, a catcher, and the discipline
      to carry an {!Error.t} rather than a bare payload across the module's own boundary. This module is that pair, with
      the wrapper built at the throw and the catch guaranteed by construction.

      It is the companion of {!Err.protect}: [protect] absorbs an exception raised by {e foreign} code, while
      [with_escape] establishes an exit for the {e current} module's own recursion. *)

  type 'e t
  (** A token authorising an exit from one {!with_escape} call. It is valid only on the call stack that {!with_escape}
      established. *)

  exception Escaped_after_exit of Source.t option
  (** Raised by {!throw} and {!throw_error} when the token's {!with_escape} call has already returned, carrying the
      throw site when [~pos] was supplied. A leaked token therefore fails where it is misused, rather than unwinding
      past every handler. *)

  val with_escape : ('e t -> 'a) -> ('a, 'e Error.t) result
  (** Run the function with a fresh token. Return [Ok] for a normal return, or [Error] carrying the wrapper from the
      first {!throw} on that token. Any other exception propagates unchanged, with its backtrace, as in {!Err.protect}.

      Each call generates its own exception, so nested and concurrent uses cannot catch one another's escapes, and a
      throw aimed at an enclosing token passes through inner frames to the one that owns it. The return type is
      [('a, 'e) Err.t].

      No event is recorded here. [Catch] describes absorbing a foreign exception, and recording it would make an
      escaping walk's trace differ from that of the equivalent monadic walk. *)

  val throw : 'e t -> ?pos:Source.pos -> ?pp_error:(Format.formatter -> 'e -> unit) -> 'e -> 'a
  (** Detect a failure and exit to its {!with_escape} frame. Records [Detect] under the active policy: the throw is the
      detection site. *)

  val throw_error : 'e t -> 'e Error.t -> 'a
  (** Exit with an already-constructed wrapper, adding no event and preserving its origin. *)

  val or_throw : 'e t -> ('a, 'e Error.t) result -> 'a
  (** Return the value, or exit with the existing wrapper. Its argument type is [('a, 'e) Err.t]: this is the bridge
      that lets a recursive walk call ordinary result-returning functions without threading results through its own
      arms. *)

  val map : ('e -> 'f) -> 'f t -> 'e t
  (** View a frame through a payload conversion. Throwing through the returned token exits the same {!with_escape}
      frame, preserves the throw's origin, and does not record a [Map] event: this adapter represents a static domain
      inclusion rather than a runtime error boundary.

      The derived token shares its parent's lifetime, so using it after the frame exits raises {!Escaped_after_exit}.
      This is useful when a recursive helper has a narrower polymorphic-variant row than its caller. *)

  val pp : Format.formatter -> 'e t -> unit
  (** Render whether this token is currently [live] or [exited]. *)
end

module Exn : sig
  type packed
  (** An existential typed error paired with its payload printer. *)

  exception E of packed
  (** Printable structured exception used at explicit boundaries. *)

  val pp : Format.formatter -> packed -> unit
  (** Render a packed error. *)

  val pp_kind : Format.formatter -> packed -> unit
  (** Render only the domain payload, omitting origin and events. Use at a boundary that must not emit provenance -- a
      wire response, a user-facing message, a log read by a third party -- where {!pp}, and therefore
      [Printexc.to_string], would be too much. *)
end

(** The exception boundary decomposed. Most code needs only {!or_raise}; the other three exist for callers that must
    build an exception without raising it, or raise one they already hold. *)

val to_exn : ?pos:Source.pos -> pp_error:(Format.formatter -> 'e -> unit) -> 'e Error.t -> exn
(** Add [Export] and construct a printable exception without raising. *)

val export_exn : ?pos:Source.pos -> pp_error:(Format.formatter -> 'e -> unit) -> ('a, 'e) t -> ('a, exn) result
(** Preserve [Ok] or convert an error using {!to_exn}. *)

val raise_error : ?pos:Source.pos -> pp_error:(Format.formatter -> 'e -> unit) -> 'e Error.t -> 'a
(** Add [Raise] and raise a printable structured exception. *)

val or_raise : ?pos:Source.pos -> pp_error:(Format.formatter -> 'e -> unit) -> ('a, 'e) t -> 'a
(** Extract [Ok] or raise through {!raise_error}. *)

(** {1 Binding a domain printer}

    Every operation above that can produce or convert an error takes [?pp_error], because the printer describes the
    payload domain that exists {e at that call}. A domain has exactly one printer, so supplying it at each call is
    repetitive; {!Make} supplies it once.

    The functor introduces no new types: [Make(D).fail] is [fail ~pp_error:D.pp_error], so bound and unbound values
    interoperate freely.

    It pays best in a module that mostly uses one error domain. Binding a printer fixes the operations obtained from
    {!Make} at that domain, so code that relies on [`Missing] inferring a smaller row before widening into several
    different domains may be clearer with the unbound operations -- or a plain function such as
    [let fail ?pos e = Err.fail ?pos ~pp_error e]. A printer written with a [[< error ]] argument is accepted by
    {!Make}; the resulting operations use the domain type supplied by the functor. *)

module type Domain = sig
  type error
  (** The domain's payload type. *)

  val pp_error : Format.formatter -> error -> unit
  (** The domain's one printer. *)
end

(** The operations of {!Err} that take a printer, with that printer already supplied. Everything else -- {!return},
    {!bind}, {!map}, {!payload}, {!Syntax}, {!List}, {!Accum} -- needs no printer and stays in {!Err}.

    Use the result qualified, as [E.fail] and [E.Error.make]. Including it in a module shadows {!Err.Error} for the rest
    of that module; the [Error] constructor of [Stdlib.result] is unaffected. *)
module type S = sig
  type error
  (** The bound payload type. *)

  val pp_error : Format.formatter -> error -> unit
  (** The bound printer. *)

  val pp : (Format.formatter -> 'a -> unit) -> Format.formatter -> ('a, error Error.t) result -> unit
  (** {!Err.pp} with the domain printer supplied. *)

  val fail : ?pos:Source.pos -> error -> ('a, error Error.t) result
  (** {!Err.fail} with the domain printer supplied. *)

  val of_option : ?pos:Source.pos -> error -> 'a option -> ('a, error Error.t) result
  (** {!Err.of_option} with the domain printer supplied. *)

  val map_none : ?pos:Source.pos -> error:(unit -> error) -> 'a option -> ('a, error Error.t) result
  (** {!Err.map_none} with the domain printer supplied. *)

  val guard : ?pos:Source.pos -> error:error -> bool -> (unit, error Error.t) result
  (** {!Err.guard} with the domain printer supplied. *)

  val map_error : ?pos:Source.pos -> ('e -> error) -> ('a, 'e Error.t) result -> ('a, error Error.t) result
  (** {!Err.map_error} into this domain. The source domain stays polymorphic: only the destination is bound, which is
      the domain whose printer the [Map] observation needs. *)

  val mark_error : ?pos:Source.pos -> Action.t -> ('a, error Error.t) result -> ('a, error Error.t) result
  (** {!Err.mark_error} with the domain printer supplied. *)

  val protect : ?pos:Source.pos -> catch:(exn -> error option) -> (unit -> 'a) -> ('a, error Error.t) result
  (** {!Err.protect} with the domain printer supplied. *)

  val import : ?pos:Source.pos -> ('e -> error) -> ('a, 'e) result -> ('a, error Error.t) result
  (** {!Err.import} into this domain. *)

  val export : ?pos:Source.pos -> ('a, error Error.t) result -> ('a, error) result
  (** {!Err.export} with the domain printer supplied. *)

  val to_exn : ?pos:Source.pos -> error Error.t -> exn
  (** {!Err.to_exn} with the domain printer supplied. *)

  val export_exn : ?pos:Source.pos -> ('a, error Error.t) result -> ('a, exn) result
  (** {!Err.export_exn} with the domain printer supplied. *)

  val raise_error : ?pos:Source.pos -> error Error.t -> 'a
  (** {!Err.raise_error} with the domain printer supplied. *)

  val or_raise : ?pos:Source.pos -> ('a, error Error.t) result -> 'a
  (** {!Err.or_raise} with the domain printer supplied. *)

  val with_escape : (error Escape.t -> 'a) -> ('a, error Error.t) result
  (** {!Err.Escape.with_escape} at this domain. *)

  val throw : error Escape.t -> ?pos:Source.pos -> error -> 'a
  (** {!Err.Escape.throw} with the domain printer supplied. *)

  (** The {!Err.Error} operations that take a printer. *)
  module Error : sig
    val make : ?pos:Source.pos -> error -> error Error.t
    (** {!Err.Error.make} with the domain printer supplied. *)

    val map_kind : ?pos:Source.pos -> ('e -> error) -> 'e Error.t -> error Error.t
    (** {!Err.Error.map_kind} into this domain. *)

    val pp : Format.formatter -> error Error.t -> unit
    (** {!Err.Error.pp} with the domain printer supplied. *)

    val pp_kind : Format.formatter -> error Error.t -> unit
    (** {!Err.Error.pp_kind} with the domain printer supplied. *)
  end
end

(** Bind a domain's printer once. A module that already exposes [type error] and [pp_error] -- the shape this library
    asks a domain to have anyway -- satisfies {!Domain} without further work. *)
module Make (D : Domain) : S with type error = D.error

(** {1 Syntax and traversals} *)

module Syntax : sig
  val ( let* ) : ('a, 'e) t -> ('a -> ('b, 'e) t) -> ('b, 'e) t
  (** Monadic binding alias of {!bind}. *)

  val ( let+ ) : ('a, 'e) t -> ('a -> 'b) -> ('b, 'e) t
  (** Successful-value map in let syntax. *)

  val ( >>= ) : ('a, 'e) t -> ('a -> ('b, 'e) t) -> ('b, 'e) t
  (** Infix alias of {!bind}. *)

  val ( >>| ) : ('a, 'e) t -> ('a -> 'b) -> ('b, 'e) t
  (** Infix successful-value map. *)
end

module List : sig
  (** Stack-safe, left-to-right traversal that stops at the first error. For a traversal that runs every element and
      reports every failure, see {!Err.Accum}.

      [filter] is omitted because {!filter_map} subsumes it, and [fold_right] because it cannot be tail-recursive
      without reversing the order in which the function observes the list, which would contradict this module's
      left-to-right contract. *)

  val map : ('a -> ('b, 'e) t) -> 'a list -> ('b list, 'e) t
  (** Traverse left to right, returning values in input order. *)

  val iter : ('a -> (unit, 'e) t) -> 'a list -> (unit, 'e) t
  (** Traverse left to right until the first error. *)

  val fold_left : ('acc -> 'a -> ('acc, 'e) t) -> 'acc -> 'a list -> ('acc, 'e) t
  (** Tail-recursive monadic left fold. *)

  val map2 :
    ?pos:Source.pos ->
    ?pp_error:(Format.formatter -> 'e -> unit) ->
    unequal_lengths:(int -> int -> 'e) ->
    ('a -> 'b -> ('c, 'e) t) ->
    'a list ->
    'b list ->
    ('c list, 'e) t
  (** Traverse two lists in step. Unlike [Stdlib.List.map2], a length mismatch is a detected error rather than
      [Invalid_argument]: [unequal_lengths] receives the left and right lengths and returns the domain payload, so this
      subsumes the length check that otherwise precedes a [List.combine]. Both lengths are validated before the first
      call to the mapping function, so a mismatch produces no partial effects and cannot be hidden by a mapping error.
      The payload is required because the library cannot invent a value in the caller's error domain. *)

  val iter2 :
    ?pos:Source.pos ->
    ?pp_error:(Format.formatter -> 'e -> unit) ->
    unequal_lengths:(int -> int -> 'e) ->
    ('a -> 'b -> (unit, 'e) t) ->
    'a list ->
    'b list ->
    (unit, 'e) t
  (** Traverse two lists in step until the first error, validating lengths before the first call and reporting a
      mismatch as in {!map2}. *)

  val filter_map : ('a -> ('b option, 'e) t) -> 'a list -> ('b list, 'e) t
  (** Traverse left to right, keeping the [Some] results in input order. *)

  val exists : ('a -> (bool, 'e) t) -> 'a list -> (bool, 'e) t
  (** Stop at the first [Ok true]; later predicates are not run. *)

  val for_all : ('a -> (bool, 'e) t) -> 'a list -> (bool, 'e) t
  (** Stop at the first [Ok false]; later predicates are not run. *)
end

module Accum : sig
  (** Stack-safe traversal that runs {e every} element and reports {e every} failure, for validators and batch passes
      that must tell a user about all their problems at once. Contrast {!Err.List}, which stops at the first error.

      These do not change {!bind} semantics; they are the applicative sibling of the monadic traversals. Because every
      element runs, so do the side effects and work of elements after a failure. On untrusted input, check the size or
      cost ceiling of a traversal before entering [Accum]; accumulating an unbounded walk defeats that ceiling. *)

  type 'e errors = 'e Error.t list
  (** Failures in input order. Each keeps its own detection origin and event trail, which is what makes a
      multi-diagnostic report useful; a bare payload list is [Stdlib.List.map Error.kind] away. *)

  val pp_errors : (Format.formatter -> 'e -> unit) -> Format.formatter -> 'e errors -> unit
  (** Render every failure through {!Error.pp}, one per line. *)

  val map : ?pos:Source.pos -> ('a -> ('b, 'e) t) -> 'a list -> ('b list, 'e errors) t
  (** Apply the function to every element. Return the values in input order, or every failure in input order. *)

  val iter : ?pos:Source.pos -> ('a -> (unit, 'e) t) -> 'a list -> (unit, 'e errors) t
  (** Apply the function to every element, collecting every failure. *)

  val all : ?pos:Source.pos -> ('a, 'e) t list -> ('a list, 'e errors) t
  (** Combine already-computed results, collecting every failure. *)

  val both : ?pos:Source.pos -> ('a, 'e) t -> ('b, 'e) t -> ('a * 'b, 'e errors) t
  (** Combine two results of different value types, reporting both failures when both fail. *)

  val lift : ('a, 'e) t -> ('a, 'e errors) t
  (** Lift one ordinary result into the accumulating error domain. An error becomes a one-element batch while retaining
      its origin and event trail. *)

  val fold_errors : ('e errors -> 'f) -> ('a, 'e errors) t -> ('a, 'f) t
  (** Collapse a batch into a payload chosen by the caller, so a function can accumulate internally without changing its
      published error domain. The combiner is mandatory because the library cannot invent a value in that domain.

      On a non-empty batch, the returned wrapper retains the first failure's origin and event trail; every failure
      remains available to the combiner. The empty case is supported for manually constructed batch errors and retains
      that batch wrapper's provenance. No [Map] event is recorded. *)
end
