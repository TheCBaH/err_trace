module Source = struct
  type pos = string * int * int * int
  type t = { file : string; line : int; start_column : int; end_column : int }

  let of_pos (file, line, start_column, end_column) = { file; line; start_column; end_column }
  let to_pos t = (t.file, t.line, t.start_column, t.end_column)
  let pp ppf t = Format.fprintf ppf "%s:%d:%d-%d" t.file t.line t.start_column t.end_column
  let pp_pos ppf pos = pp ppf (of_pos pos)
end

module Action = struct
  type t = Detect | Map | Filter | Catch | Raise | Import | Export

  (* The one enumeration of the action language. [Action.Set.all], the empty
     complement used by [boundaries], both printers, and the configuration
     parser all derive from it, so adding a constructor cannot leave one of
     them silently behind. *)
  let order = [ Detect; Map; Filter; Catch; Raise; Import; Export ]

  let to_string = function
    | Detect -> "detect"
    | Map -> "map"
    | Filter -> "filter"
    | Catch -> "catch"
    | Raise -> "raise"
    | Import -> "import"
    | Export -> "export"

  let of_string name = List.find_opt (fun action -> to_string action = name) order
  let pp ppf action = Format.pp_print_string ppf (to_string action)

  module Set = struct
    type action = t
    type t = int

    let bit = function Detect -> 1 | Map -> 2 | Filter -> 4 | Catch -> 8 | Raise -> 16 | Import -> 32 | Export -> 64
    let empty = 0
    let of_list xs = List.fold_left (fun set action -> set lor bit action) empty xs
    let all = of_list order
    let boundaries = of_list (List.filter (fun action -> action <> Detect) order)
    let mem action set = set land bit action <> 0
    let add action set = set lor bit action
    let remove action set = set land lnot (bit action)
    let union = ( lor )
    let to_list set = List.filter (fun action -> mem action set) order
    let equal = Int.equal

    let pp ppf set =
      let selected = List.filter (fun action -> mem action set) order in
      match selected with
      | [] -> Format.pp_print_string ppf "off"
      | action :: actions ->
          Format.fprintf ppf "@[<hov>%a" pp action;
          List.iter (fun action -> Format.fprintf ppf ",@ %a" pp action) actions;
          Format.fprintf ppf "@]"
  end
end

type backtrace_policy = Never | Origin | Events

type config = {
  actions : Action.Set.t;
  backtrace : backtrace_policy;
  max_events : int;
  max_frames : int;
  max_external_bytes : int;
}

(* OCaml integers have 31 value bits on a 32-bit runtime. *)
let max_32_bit_limit = 0x3fff_ffff

(* Each retained event can carry a stack of up to [max_frames] frames, so an
   unbounded trail is an unbounded allocation per error. *)
let max_events_cap = 4096

let fast_config =
  { actions = Action.Set.empty; backtrace = Never; max_events = 0; max_frames = 0; max_external_bytes = 16 * 1024 }

let with_stacks_config =
  {
    actions = Action.Set.boundaries;
    backtrace = Origin;
    max_events = 32;
    max_frames = 32;
    max_external_bytes = 16 * 1024;
  }

(* [max_frames = 0] is redundant with [Never] and states the intent totally.
   [max_external_bytes] keeps the shared bound rather than 0: [Stack.of_external]
   is an explicit adapter call, not automatic capture, so zeroing it would
   silently truncate a stack the caller deliberately imported. *)
let deterministic_config =
  {
    actions = Action.Set.boundaries;
    backtrace = Never;
    max_events = 32;
    max_frames = 0;
    max_external_bytes = 16 * 1024;
  }

let debug_config =
  { actions = Action.Set.all; backtrace = Events; max_events = 64; max_frames = 64; max_external_bytes = 16 * 1024 }

let current_config = Atomic.make deterministic_config

module Stack = struct
  type t =
    | Raw of Printexc.raw_backtrace
    | Slots of Printexc.backtrace_slot array
    | External of { runtime : string; stack : string; truncated : bool }

  let of_raw_backtrace backtrace = Raw backtrace

  (* Prefer the last whole line inside the limit; a single line longer than the
     limit is cut at a UTF-8 character boundary instead. *)
  let cut_point stack limit =
    if stack.[limit] = '\n' then limit
    else
      match String.rindex_from_opt stack (limit - 1) '\n' with
      | Some line_end when line_end > 0 -> line_end
      | _ ->
          let rec back cut = if cut > 0 && Char.code stack.[cut] land 0xC0 = 0x80 then back (cut - 1) else cut in
          back limit

  let of_external ~runtime ~stack =
    let limit = (Atomic.get current_config).max_external_bytes in
    let truncated = String.length stack > limit in
    let stack = if truncated then String.sub stack 0 (cut_point stack limit) else stack in
    External { runtime; stack; truncated }

  (* [Printexc.backtrace_slots], not [raw_backtrace_length]. Melange's
     [get_callstack] hands back a value its own [raw_backtrace_length] cannot
     read -- the generated code is [bt.length], and the value is [undefined], so
     asking for the length throws a TypeError out of a printer. Its
     [backtrace_slots] converts defensively and answers [None], which is the
     honest answer on that backend and is safe on all three.

     Native behaviour is unchanged where it matters and better where it does
     not: a binary built without -g has frames whose symbols the runtime cannot
     resolve, and reporting those as unavailable is what every caller of this
     predicate already wanted. *)
  let raw_is_available backtrace =
    match Printexc.backtrace_slots backtrace with Some slots -> Array.length slots <> 0 | None -> false

  (* The stack of an exception caught by [protect], bounded to [max_frames]
     when it is retained. Slots rather than raw entries: there is no way back
     from a cut array of entries to a [raw_backtrace], and Melange's entry
     accessors throw where [backtrace_slots] answers [None]. A stack that fits
     is kept raw, so it can still be re-raised. *)
  let of_caught ~max_frames backtrace =
    if max_frames <= 0 then None
    else
      match Printexc.backtrace_slots backtrace with
      | None -> None
      | Some slots when Array.length slots <= max_frames -> Some (Raw backtrace)
      | Some slots -> Some (Slots (Array.sub slots 0 max_frames))

  let is_available = function
    | Raw backtrace -> raw_is_available backtrace
    | Slots slots -> Array.length slots <> 0
    | External { stack; _ } -> stack <> ""

  let to_raw_backtrace = function Raw backtrace -> Some backtrace | Slots _ | External _ -> None

  let to_external = function
    | External { runtime; stack; truncated } -> Some (runtime, stack, truncated)
    | Raw _ | Slots _ -> None

  let pp_lines ppf text =
    match String.split_on_char '\n' text with
    | [] -> ()
    | line :: lines ->
        Format.pp_print_string ppf line;
        List.iter (fun line -> Format.fprintf ppf "@,%s" line) lines

  (* Built from slots, not [raw_backtrace_to_string]: that text starts with
     "Raised by primitive operation" for a call stack that raised nothing, ends
     in a newline, and its first frames are this library's own. *)
  let slot_line slot =
    let location =
      Option.map
        (fun (location : Printexc.location) ->
          Format.asprintf "%a" Source.pp
            {
              Source.file = location.filename;
              line = location.line_number;
              start_column = location.start_char;
              end_column = location.end_char;
            })
        (Printexc.Slot.location slot)
    in
    match (location, Printexc.Slot.name slot) with
    | Some location, Some name -> Some (location ^ " " ^ name)
    | Some location, None -> Some location
    | None, Some name -> Some (name ^ " (unknown location)")
    | None, None -> None

  let is_own_frame slot =
    match Printexc.Slot.name slot with
    | Some name -> String.length name >= 4 && String.sub name 0 4 = "Err."
    | None -> false

  let rec drop_own_frames = function slot :: slots when is_own_frame slot -> drop_own_frames slots | slots -> slots
  let slot_lines slots = List.filter_map slot_line (drop_own_frames (Array.to_list slots))

  let pp_slots ppf slots =
    match slot_lines slots with
    | [] -> Format.pp_print_string ppf "stack unavailable"
    | line :: lines ->
        Format.pp_print_string ppf line;
        List.iter (fun line -> Format.fprintf ppf "@,%s" line) lines

  let pp ppf stack =
    Format.fprintf ppf "@[<v>";
    (match stack with
    | Raw backtrace when not (raw_is_available backtrace) -> Format.pp_print_string ppf "stack unavailable"
    | Raw backtrace -> (
        match Printexc.backtrace_slots backtrace with
        | Some slots -> pp_slots ppf slots
        | None -> Format.pp_print_string ppf "stack unavailable")
    | Slots slots when slot_lines slots = [] -> Format.pp_print_string ppf "stack unavailable"
    | Slots slots -> Format.fprintf ppf "%a@,[truncated]" pp_slots slots
    | External { stack = ""; _ } -> Format.pp_print_string ppf "stack unavailable"
    | External { runtime; stack; truncated } ->
        Format.fprintf ppf "%s stack:@,%a" runtime pp_lines stack;
        if truncated then Format.fprintf ppf "@,[truncated]");
    Format.fprintf ppf "@]"
end

(* Re-raise while preserving the original backtrace where that is possible.

   [Printexc.raise_with_backtrace] compiles to [caml_restore_raw_backtrace],
   which Melange does not implement: calling it there throws "not polyfilled"
   and so replaces the exception being propagated with an unrelated one. That
   turns every foreign exception crossing [protect] or [Escape.with_escape] into
   a spurious failure under any policy that captures stacks, such as
   [with_stacks].

   Reattach only when the captured backtrace has resolvable frames. That is
   exactly when reattaching preserves something, it is false on Melange, and it
   is also false for a native binary built without [-g], where the frames could
   not have been rendered anyway.

   This raw backtrace is captured independently of the tracing policy. The
   policy controls provenance retained in typed errors; it must not change the
   semantics of an unrelated exception that merely crosses an Err boundary. *)
let reraise exn backtrace =
  if Stack.raw_is_available backtrace then Printexc.raise_with_backtrace exn backtrace else raise exn

module Origin = struct
  type t = { source : Source.t option; stack : Stack.t option }

  let make ?source ?stack () = match (source, stack) with None, None -> None | _ -> Some { source; stack }
  let source origin = origin.source
  let stack origin = origin.stack

  let pp ppf origin =
    Format.fprintf ppf "@[<v>";
    (match (origin.source, origin.stack) with
    | Some source, Some stack -> Format.fprintf ppf "%a@,%a" Source.pp source Stack.pp stack
    | Some source, None -> Source.pp ppf source
    | None, Some stack -> Stack.pp ppf stack
    | None, None -> ());
    Format.fprintf ppf "@]"
end

module Event = struct
  type t = { action : Action.t; origin : Origin.t option }

  let action event = event.action
  let origin event = event.origin

  let pp_action ppf = function
    | Action.Detect -> Format.pp_print_string ppf "detected"
    | Action.Map -> Format.pp_print_string ppf "mapped"
    | Action.Filter -> Format.pp_print_string ppf "filtered"
    | Action.Catch -> Format.pp_print_string ppf "caught"
    | Action.Raise -> Format.pp_print_string ppf "raised"
    | Action.Import -> Format.pp_print_string ppf "imported"
    | Action.Export -> Format.pp_print_string ppf "exported"

  let pp ppf event =
    Format.fprintf ppf "@[<v>%a" pp_action event.action;
    (match event.origin with None -> () | Some origin -> Format.fprintf ppf " at %a" Origin.pp origin);
    Format.fprintf ppf "@]"

  let pp_events ppf = function
    | [] -> ()
    | event :: events ->
        pp ppf event;
        List.iter (fun event -> Format.fprintf ppf "@,%a" pp event) events
end

module Observation = struct
  type t = {
    event : Event.t;
    error_origin : Origin.t option;
    retained_events : Event.t list;
    dropped_events : int;
    is_creation : bool;
    printer : (Format.formatter -> unit) option;
  }

  let event observation = observation.event
  let error_origin observation = observation.error_origin
  let retained_events observation = observation.retained_events
  let dropped_events observation = observation.dropped_events
  let is_creation observation = observation.is_creation

  let pp ppf observation =
    match observation.printer with
    | Some printer -> printer ppf
    | None ->
        Format.fprintf ppf "@[<v>event: %a" Event.pp observation.event;
        (match observation.error_origin with
        | None -> ()
        | Some origin -> Format.fprintf ppf "@,error detected at:@,  @[<v>%a@]" Origin.pp origin);
        (match observation.retained_events with
        | [] -> ()
        | events -> Format.fprintf ppf "@,retained trace:@,  @[<v>%a@]" Event.pp_events events);
        if observation.dropped_events <> 0 then
          Format.fprintf ppf "@,%d trace event%s not retained" observation.dropped_events
            (if observation.dropped_events = 1 then "" else "s");
        Format.fprintf ppf "@]"
end

module Monitor = struct
  type entry = {
    active : bool Atomic.t;
    actions : Action.Set.t;
    callback : Observation.t -> unit;
    on_error : exn -> Stack.t option -> unit;
    on_failure : exn -> [ `Keep | `Remove ];
    last_failure : (exn * Stack.t option) option Atomic.t;
  }

  type t = entry
  type callback = Observation.t -> unit

  (* In installation order, so dispatch needs no reversal. *)
  let registry : entry list Atomic.t = Atomic.make []

  let install ?(actions = Action.Set.all) ?(on_error = fun _ _ -> ()) ?(on_failure = fun _ -> `Remove) callback =
    let entry =
      { active = Atomic.make true; actions; callback; on_error; on_failure; last_failure = Atomic.make None }
    in
    let rec add () =
      let previous = Atomic.get registry in
      if not (Atomic.compare_and_set registry previous (previous @ [ entry ])) then add ()
    in
    add ();
    entry

  let remove entry =
    if not (Atomic.compare_and_set entry.active true false) then false
    else
      let rec drop () =
        let previous = Atomic.get registry in
        let next = List.filter (fun candidate -> candidate != entry) previous in
        if not (Atomic.compare_and_set registry previous next) then drop ()
      in
      drop ();
      true

  let last_failure entry = Atomic.get entry.last_failure
  let pp ppf entry = Format.pp_print_string ppf (if Atomic.get entry.active then "installed" else "removed")
  let pp_callback ppf _ = Format.pp_print_string ppf "<callback>"

  let callback_stack () =
    match (Atomic.get current_config).backtrace with
    | Never -> None
    | Origin | Events ->
        let stack = Stack.of_raw_backtrace (Printexc.get_raw_backtrace ()) in
        if Stack.is_available stack then Some stack else None

  let matches action entry = Atomic.get entry.active && Action.Set.mem action entry.actions

  let rec any_matches action = function
    | [] -> false
    | entry :: entries -> matches action entry || any_matches action entries

  (* The monitors that match are fixed when dispatch starts: one removed by an
     earlier callback of this dispatch is still called, and an event nobody
     matches costs a scan and no allocation. *)
  let dispatch action make_observation =
    let installed = Atomic.get registry in
    if any_matches action installed then begin
      let entries = List.filter (matches action) installed in
      let observation = make_observation () in
      List.iter
        (fun entry ->
          try entry.callback observation
          with exn -> (
            let stack = callback_stack () in
            Atomic.set entry.last_failure (Some (exn, stack));
            if (try entry.on_failure exn with _ -> `Remove) = `Remove then ignore (remove entry);
            try entry.on_error exn stack with _ -> ()))
        entries
    end
end

module Error = struct
  type +'e t = {
    kind : 'e;
    origin : Origin.t option;
    events_rev : Event.t list;
    event_count : int;
    dropped_events : int;
  }

  let kind error = error.kind
  let origin error = error.origin
  let events error = List.rev error.events_rev
  let dropped_events error = error.dropped_events

  let with_kind_untraced kind error =
    {
      kind;
      origin = error.origin;
      events_rev = error.events_rev;
      event_count = error.event_count;
      dropped_events = error.dropped_events;
    }

  let map_kind_untraced f error = with_kind_untraced (f error.kind) error
  let pp_events = Event.pp_events
  let pp_kind pp_kind ppf error = pp_kind ppf error.kind

  let pp pp_kind ppf error =
    Format.fprintf ppf "@[<v>%a" pp_kind error.kind;
    (match error.origin with
    | None -> ()
    | Some origin -> Format.fprintf ppf "@,detected at:@,  @[<v>%a@]" Origin.pp origin);
    (match events error with [] -> () | events -> Format.fprintf ppf "@,trace:@,  @[<v>%a@]" pp_events events);
    if error.dropped_events <> 0 then
      Format.fprintf ppf "@,%d trace event%s not retained" error.dropped_events
        (if error.dropped_events = 1 then "" else "s");
    Format.fprintf ppf "@]"

  let make_at ~origin kind = { kind; origin; events_rev = []; event_count = 0; dropped_events = 0 }

  let capture config ?source purpose =
    let stack =
      match (config.backtrace, purpose) with
      | Never, _ | Origin, `Event -> None
      | Origin, `Origin | Events, _ -> Some (Stack.of_raw_backtrace (Printexc.get_callstack config.max_frames))
    in
    Origin.make ?source ?stack ()

  let saturating_add left right = if right > max_int - left then max_int else left + right

  let add_event ?config ?(creation = false) ?pos ?pp_error action error =
    let config = match config with Some config -> config | None -> Atomic.get current_config in
    if not (Action.Set.mem action config.actions) then error
    else
      let source = Option.map Source.of_pos pos in
      let event = { Event.action; origin = capture config ?source `Event } in
      let candidate_count = error.event_count + 1 in
      let retained_count = min config.max_events candidate_count in
      let discarded_count = candidate_count - retained_count in
      let events_rev =
        if retained_count = 0 then []
        else if discarded_count = 0 then event :: error.events_rev
        else
          let rec take remaining = function
            | _ when remaining = 0 -> []
            | [] -> []
            | item :: items -> item :: take (remaining - 1) items
          in
          take retained_count (event :: error.events_rev)
      in
      let error =
        {
          error with
          events_rev;
          event_count = retained_count;
          dropped_events = saturating_add error.dropped_events discarded_count;
        }
      in
      let printer = match pp_error with None -> None | Some pp_error -> Some (fun ppf -> pp pp_error ppf error) in
      Monitor.dispatch (Event.action event) (fun () ->
          {
            Observation.event;
            error_origin = error.origin;
            retained_events = List.rev error.events_rev;
            dropped_events = error.dropped_events;
            is_creation = creation;
            printer;
          });
      error

  let make ?pos ?pp_error kind =
    let config = Atomic.get current_config in
    let source = Option.map Source.of_pos pos in
    let error = make_at ~origin:(capture config ?source `Origin) kind in
    add_event ~config ~creation:true ?pos ?pp_error Action.Detect error

  let map_kind ?pos ?pp_error f error = add_event ?pos ?pp_error Action.Map (map_kind_untraced f error)
end

type ('a, 'e) t = ('a, 'e Error.t) result

module Config = struct
  type backtrace = backtrace_policy = Never | Origin | Events
  type t = config
  type limit = [ `Max_events | `Max_frames | `Max_external_bytes ]
  type make_error = [ `Negative_limit of limit * int | `Limit_too_large of limit * int ]

  type of_strings_error =
    [ make_error
    | `Invalid_limit of limit * string
    | `Unknown_backtrace_mode of string
    | `Unknown_trace_action of string
    | `Empty_trace_action of int ]

  (* [Never] prints as [off] so that the two configuration axes name the disabled
     state with one word, and so that this printer's output is accepted by
     {!of_strings}. The OCaml constructor stays [Never] because that is the right
     word for a guarantee in code. *)
  let pp_backtrace ppf = function
    | Never -> Format.pp_print_string ppf "off"
    | Origin -> Format.pp_print_string ppf "origin"
    | Events -> Format.pp_print_string ppf "events"

  let pp_limit ppf = function
    | `Max_events -> Format.pp_print_string ppf "max_events"
    | `Max_frames -> Format.pp_print_string ppf "max_frames"
    | `Max_external_bytes -> Format.pp_print_string ppf "max_external_bytes"

  let pp_make_error ppf = function
    | `Negative_limit (limit, value) -> Format.fprintf ppf "%a must be non-negative (got %d)" pp_limit limit value
    | `Limit_too_large (`Max_events, value) when value <= max_32_bit_limit ->
        Format.fprintf ppf "max_events must be at most %d (got %d)" max_events_cap value
    | `Limit_too_large (limit, value) ->
        Format.fprintf ppf "%a must fit on a 32-bit OCaml runtime (got %d)" pp_limit limit value

  let pp_of_strings_error ppf = function
    | #make_error as error -> pp_make_error ppf error
    | `Invalid_limit (limit, value) -> Format.fprintf ppf "%a must be an integer (got %S)" pp_limit limit value
    | `Unknown_backtrace_mode value ->
        Format.fprintf ppf "unknown backtrace mode %S (expected off, never, origin, or events)" value
    | `Unknown_trace_action value -> Format.fprintf ppf "unknown trace action %S" value
    | `Empty_trace_action position -> Format.fprintf ppf "empty trace action at position %d" position

  let invalid_limit limit value =
    if value < 0 then Some (`Negative_limit (limit, value))
    else if value > max_32_bit_limit || (limit = `Max_events && value > max_events_cap) then
      Some (`Limit_too_large (limit, value))
    else None

  let validate ~actions ~backtrace ~max_events ~max_frames ~max_external_bytes =
    match
      ( invalid_limit `Max_events max_events,
        invalid_limit `Max_frames max_frames,
        invalid_limit `Max_external_bytes max_external_bytes )
    with
    | Some error, _, _ | _, Some error, _ | _, _, Some error -> Error error
    | None, None, None -> Ok { actions; backtrace; max_events; max_frames; max_external_bytes }

  let make ~actions ~backtrace ~max_events ~max_frames ~max_external_bytes =
    match validate ~actions ~backtrace ~max_events ~max_frames ~max_external_bytes with
    | Ok config -> Ok config
    | Error error -> Error (Error.make ~pp_error:pp_make_error (error : make_error))

  let fast = fast_config
  let deterministic = deterministic_config
  let with_stacks = with_stacks_config
  let initial = deterministic_config
  let debug = debug_config
  let get () = Atomic.get current_config
  let set config = Atomic.set current_config config

  let with_config config f =
    let previous = get () in
    set config;
    Fun.protect ~finally:(fun () -> set previous) f

  let actions config = config.actions
  let backtrace config = config.backtrace
  let max_events config = config.max_events
  let max_frames config = config.max_frames
  let max_external_bytes config = config.max_external_bytes

  let pp ppf config =
    Format.fprintf ppf
      "@[<hov 2>{ actions = %a;@ backtrace = %a;@ max_events = %d;@ max_frames = %d;@ max_external_bytes = %d }@]"
      Action.Set.pp config.actions pp_backtrace config.backtrace config.max_events config.max_frames
      config.max_external_bytes

  (* [Set.t] is a bit mask, so a group name in a list is a union. *)
  let parse_actions = function
    | None | Some "" -> Ok initial.actions
    | Some value ->
        let rec loop selected position = function
          | [] -> Ok selected
          | name :: names -> (
              (* [Action.Set.pp] separates with a break hint, which renders as a
                 space or a newline. Trimming here is what lets a printed policy
                 be parsed back. *)
              let name = String.trim name in
              let group set = loop (selected lor set) (position + 1) names in
              match name with
              | "" -> Error (`Empty_trace_action position)
              | "off" -> group Action.Set.empty
              | "boundaries" -> group Action.Set.boundaries
              | "all" -> group Action.Set.all
              | _ -> (
                  match Action.of_string name with
                  | Some parsed -> group (Action.Set.of_list [ parsed ])
                  | None -> Error (`Unknown_trace_action name)))
        in
        loop Action.Set.empty 1 (String.split_on_char ',' value)

  (* Both spellings of the disabled state are accepted: [off] is what
     {!pp_backtrace} prints and what [trace] uses, [never] names the constructor
     and was this parser's output in earlier revisions. *)
  let parse_backtrace = function
    | None -> Ok initial.backtrace
    | Some ("off" | "never") -> Ok Never
    | Some "origin" -> Ok Origin
    | Some "events" -> Ok Events
    | Some value -> Error (`Unknown_backtrace_mode value)

  (* [int_of_string_opt] also reads [0x10], [0b11] and [1_000], and on a 32-bit
     runtime reports a 31-bit overflow as a non-integer. Digits only, with
     overflow reported as such. *)
  let parse_integer input =
    let length = String.length input in
    let negative = length > 0 && input.[0] = '-' in
    let start = if negative || (length > 0 && input.[0] = '+') then 1 else 0 in
    let rec all_digits index =
      index = length || (input.[index] >= '0' && input.[index] <= '9' && all_digits (index + 1))
    in
    let rec accumulate index acc =
      if index = length then `Value (if negative then -acc else acc)
      else
        let digit = Char.code input.[index] - Char.code '0' in
        if acc > (max_int - digit) / 10 then `Overflow negative else accumulate (index + 1) ((acc * 10) + digit)
    in
    if start >= length || not (all_digits start) then None else Some (accumulate start 0)

  let parse_limit limit = function
    | None -> Ok None
    | Some input -> (
        match parse_integer (String.trim input) with
        | None -> Error (`Invalid_limit (limit, input))
        | Some (`Overflow true) -> Error (`Negative_limit (limit, min_int))
        | Some (`Overflow false) -> Error (`Limit_too_large (limit, max_int))
        | Some (`Value value) -> (
            match invalid_limit limit value with None -> Ok (Some value) | Some error -> Error error))

  let value_or default = function Some value -> value | None -> default

  (* Surrounding whitespace is never significant in a mode name, and accepting it
     is what lets a policy rendered by {!pp} be fed back through this parser. *)
  let trimmed = Option.map String.trim

  let of_strings ~trace ~backtrace ~max_events ~max_frames ~max_external_bytes : (t, of_strings_error Error.t) result =
    match
      ( parse_actions (trimmed trace),
        parse_backtrace (trimmed backtrace),
        parse_limit `Max_events max_events,
        parse_limit `Max_frames max_frames,
        parse_limit `Max_external_bytes max_external_bytes )
    with
    | Ok actions, Ok backtrace, Ok max_events, Ok max_frames, Ok max_external_bytes -> (
        let max_events = value_or initial.max_events max_events in
        let max_frames = value_or initial.max_frames max_frames in
        let max_external_bytes = value_or initial.max_external_bytes max_external_bytes in
        match validate ~actions ~backtrace ~max_events ~max_frames ~max_external_bytes with
        | Ok config -> Ok config
        | Error error -> Error (Error.make ~pp_error:pp_of_strings_error (error : make_error :> of_strings_error)))
    | Error error, _, _, _, _
    | _, Error error, _, _, _
    | _, _, Error error, _, _
    | _, _, _, Error error, _
    | _, _, _, _, Error error ->
        Error (Error.make ~pp_error:pp_of_strings_error (error : of_strings_error))
end

let pp pp_value pp_error ppf = function
  | Ok value -> Format.fprintf ppf "@[<hov 2>Ok@ (%a)@]" pp_value value
  | Error error -> Format.fprintf ppf "@[<hov 2>Error@ (%a)@]" (Error.pp pp_error) error

let return value = Ok value
let fail ?pos ?pp_error kind = Error (Error.make ?pos ?pp_error kind)
let of_option ?pos ?pp_error error = function Some value -> Ok value | None -> fail ?pos ?pp_error error
let map_none ?pos ?pp_error ~error = function Some value -> Ok value | None -> fail ?pos ?pp_error (error ())

let guard ?pos ?pp_error ~error condition =
  if condition then Ok ()
  else
    let config = Config.get () in
    let source = Option.map Source.of_pos pos in
    let error = Error.make_at ~origin:(Error.capture config ?source `Origin) error in
    Error (Error.add_event ~config ~creation:true ?pos ?pp_error Action.Filter error)

let map f = function Ok value -> Ok (f value) | Error error -> Error error
let bind result f = match result with Ok value -> f value | Error error -> Error error

let map_error ?pos ?pp_error f = function
  | Ok value -> Ok value
  | Error error -> Error (Error.map_kind ?pos ?pp_error f error)

let mark_error ?pos ?pp_error action = function
  | Ok value -> Ok value
  | Error error -> Error (Error.add_event ?pos ?pp_error action error)

let payload = function Ok value -> Ok value | Error error -> Error (Error.kind error)

(* Only [Import] is recorded, not [Detect]: the failure was detected by whoever
   produced the bare result. This follows [guard], which likewise attaches its
   single semantic event to an origin built without a detection event. *)
let import ?pos ?pp_error f = function
  | Ok value -> Ok value
  | Error kind ->
      let config = Config.get () in
      let source = Option.map Source.of_pos pos in
      let error = Error.make_at ~origin:(Error.capture config ?source `Origin) (f kind) in
      Error (Error.add_event ~config ~creation:true ?pos ?pp_error Action.Import error)

let export ?pos ?pp_error result = payload (mark_error ?pos ?pp_error Action.Export result)

let protect ?pos ?pp_error ~catch f =
  try Ok (f ())
  with exn -> (
    let config = Config.get () in
    let raw_backtrace = Printexc.get_raw_backtrace () in
    match catch exn with
    | None -> reraise exn raw_backtrace
    | Some kind ->
        let source = Option.map Source.of_pos pos in
        let stack =
          match Config.backtrace config with
          | Config.Never -> None
          | Config.Origin | Config.Events -> Stack.of_caught ~max_frames:(Config.max_frames config) raw_backtrace
        in
        let origin = Origin.make ?source ?stack () in
        Error (Error.add_event ~config ~creation:true ?pos ?pp_error Action.Catch (Error.make_at ~origin kind)))

module Escape = struct
  (* [make_exn] closes over the constructor generated by one [with_escape] call.
     Storing the constructor rather than an identifier is what makes a token
     unable to unwind to any frame but its own, without a runtime check. *)
  type 'e t = { live : bool ref; make_exn : 'e Error.t -> exn }

  exception Escaped_after_exit of Source.t option

  let pp ppf token = Format.pp_print_string ppf (if !(token.live) then "live" else "exited")

  let with_escape (type a e) (f : e t -> a) : (a, e Error.t) result =
    (* Generative: each evaluation of [with_escape] allocates a fresh extension
       constructor, so nested and concurrent frames cannot catch each other's
       escapes, and a throw aimed at an outer token passes through inner
       handlers to the frame that owns it. *)
    let exception Escaped of e Error.t in
    let token = { live = ref true; make_exn = (fun error -> Escaped error) } in
    match f token with
    | value ->
        token.live := false;
        Ok value
    | exception Escaped error ->
        token.live := false;
        Error error
    | exception exn ->
        (* A foreign exception is re-raised with its backtrace, exactly as
           [protect] does for exceptions its [catch] declines. *)
        let raw_backtrace = Printexc.get_raw_backtrace () in
        token.live := false;
        reraise exn raw_backtrace

  let throw_error ?pos token error =
    if !(token.live) then raise (token.make_exn error) else raise (Escaped_after_exit (Option.map Source.of_pos pos))

  let throw token ?pos ?pp_error kind =
    if not !(token.live) then raise (Escaped_after_exit (Option.map Source.of_pos pos));
    raise (token.make_exn (Error.make ?pos ?pp_error kind))

  let or_throw ?pos token = function Ok value -> value | Error error -> throw_error ?pos token error
  let map f token = { live = token.live; make_exn = (fun error -> token.make_exn (Error.map_kind_untraced f error)) }

  let printer = function
    | Escaped_after_exit source ->
        let where = match source with None -> "" | Some source -> Format.asprintf " (at %a)" Source.pp source in
        Some ("Err.Escape.throw called after its with_escape call returned" ^ where)
    | _ -> None

  let () = Printexc.register_printer printer
end

module Exn = struct
  type packed = Pack : 'e Error.t * (Format.formatter -> 'e -> unit) -> packed

  exception E of packed

  let pp ppf (Pack (error, pp_error)) = Error.pp pp_error ppf error

  (* The payload alone, for a boundary that must NOT emit provenance: anything
     rendering into a wire response, a user-facing CLI message, or a log a
     third party reads. Without this such a boundary has only [pp], which is a
     developer diagnostic, so it would either ship the source's own frames
     outward or re-derive the payload printer it has already been handed. *)
  let pp_kind ppf (Pack (error, pp_error)) = pp_error ppf (Error.kind error)
  let origin (Pack (error, _)) = Error.origin error
  let events (Pack (error, _)) = Error.events error
  let dropped_events (Pack (error, _)) = Error.dropped_events error
  let printer = function E packed -> Some (Format.asprintf "%a" pp packed) | _ -> None
  let () = Printexc.register_printer printer
end

let to_exn ?pos ~pp_error error =
  let error = Error.add_event ?pos ~pp_error Action.Export error in
  Exn.E (Exn.Pack (error, pp_error))

let export_exn ?pos ~pp_error = function Ok value -> Ok value | Error error -> Error (to_exn ?pos ~pp_error error)

let raise_error ?pos ~pp_error error =
  let error = Error.add_event ?pos ~pp_error Action.Raise error in
  raise (Exn.E (Exn.Pack (error, pp_error)))

let or_raise ?pos ~pp_error = function Ok value -> value | Error error -> raise_error ?pos ~pp_error error

module type Domain = sig
  type error

  val pp_error : Format.formatter -> error -> unit
end

module type S = sig
  type error

  val pp_error : Format.formatter -> error -> unit
  val pp : (Format.formatter -> 'a -> unit) -> Format.formatter -> ('a, error Error.t) result -> unit
  val fail : ?pos:Source.pos -> error -> ('a, error Error.t) result
  val of_option : ?pos:Source.pos -> error -> 'a option -> ('a, error Error.t) result
  val map_none : ?pos:Source.pos -> error:(unit -> error) -> 'a option -> ('a, error Error.t) result
  val guard : ?pos:Source.pos -> error:error -> bool -> (unit, error Error.t) result
  val map_error : ?pos:Source.pos -> ('e -> error) -> ('a, 'e Error.t) result -> ('a, error Error.t) result
  val mark_error : ?pos:Source.pos -> Action.t -> ('a, error Error.t) result -> ('a, error Error.t) result
  val protect : ?pos:Source.pos -> catch:(exn -> error option) -> (unit -> 'a) -> ('a, error Error.t) result
  val import : ?pos:Source.pos -> ('e -> error) -> ('a, 'e) result -> ('a, error Error.t) result
  val export : ?pos:Source.pos -> ('a, error Error.t) result -> ('a, error) result
  val to_exn : ?pos:Source.pos -> error Error.t -> exn
  val export_exn : ?pos:Source.pos -> ('a, error Error.t) result -> ('a, exn) result
  val raise_error : ?pos:Source.pos -> error Error.t -> 'a
  val or_raise : ?pos:Source.pos -> ('a, error Error.t) result -> 'a
  val with_escape : (error Escape.t -> 'a) -> ('a, error Error.t) result
  val throw : error Escape.t -> ?pos:Source.pos -> error -> 'a

  module List : sig
    val map2 :
      ?pos:Source.pos ->
      unequal_lengths:(int -> int -> error) ->
      ('a -> 'b -> ('c, error Error.t) result) ->
      'a list ->
      'b list ->
      ('c list, error Error.t) result

    val iter2 :
      ?pos:Source.pos ->
      unequal_lengths:(int -> int -> error) ->
      ('a -> 'b -> (unit, error Error.t) result) ->
      'a list ->
      'b list ->
      (unit, error Error.t) result
  end

  module Error : sig
    val make : ?pos:Source.pos -> error -> error Error.t
    val map_kind : ?pos:Source.pos -> ('e -> error) -> 'e Error.t -> error Error.t
    val pp : Format.formatter -> error Error.t -> unit
    val pp_kind : Format.formatter -> error Error.t -> unit
  end
end

module List = struct
  let map f values =
    let rec loop mapped = function
      | [] -> Ok (Stdlib.List.rev mapped)
      | value :: values -> (
          match f value with Ok mapped_value -> loop (mapped_value :: mapped) values | Error error -> Error error)
    in
    loop [] values

  let iter f values =
    let rec loop = function
      | [] -> Ok ()
      | value :: values -> ( match f value with Ok () -> loop values | Error error -> Error error)
    in
    loop values

  let fold_left f initial values =
    let rec loop accumulator = function
      | [] -> Ok accumulator
      | value :: values -> (
          match f accumulator value with Ok accumulator -> loop accumulator values | Error error -> Error error)
    in
    loop initial values

  let unequal ?pos ?pp_error ~unequal_lengths left_length right_length =
    fail ?pos ?pp_error (unequal_lengths left_length right_length)

  let map2 ?pos ?pp_error ~unequal_lengths f left right =
    let left_length = Stdlib.List.length left in
    let right_length = Stdlib.List.length right in
    if left_length <> right_length then unequal ?pos ?pp_error ~unequal_lengths left_length right_length
    else
      let rec loop mapped lefts rights =
        match (lefts, rights) with
        | [], [] -> Ok (Stdlib.List.rev mapped)
        | left_value :: lefts, right_value :: rights -> (
            match f left_value right_value with
            | Ok mapped_value -> loop (mapped_value :: mapped) lefts rights
            | Error error -> Error error)
        | _ :: _, [] | [], _ :: _ -> assert false
      in
      loop [] left right

  let iter2 ?pos ?pp_error ~unequal_lengths f left right =
    let left_length = Stdlib.List.length left in
    let right_length = Stdlib.List.length right in
    if left_length <> right_length then unequal ?pos ?pp_error ~unequal_lengths left_length right_length
    else
      let rec loop lefts rights =
        match (lefts, rights) with
        | [], [] -> Ok ()
        | left_value :: lefts, right_value :: rights -> (
            match f left_value right_value with Ok () -> loop lefts rights | Error error -> Error error)
        | _ :: _, [] | [], _ :: _ -> assert false
      in
      loop left right

  let filter_map f values =
    let rec loop kept = function
      | [] -> Ok (Stdlib.List.rev kept)
      | value :: values -> (
          match f value with
          | Ok None -> loop kept values
          | Ok (Some kept_value) -> loop (kept_value :: kept) values
          | Error error -> Error error)
    in
    loop [] values

  let exists f values =
    let rec loop = function
      | [] -> Ok false
      | value :: values -> (
          match f value with Ok false -> loop values | Ok true -> Ok true | Error error -> Error error)
    in
    loop values

  let for_all f values =
    let rec loop = function
      | [] -> Ok true
      | value :: values -> (
          match f value with Ok true -> loop values | Ok false -> Ok false | Error error -> Error error)
    in
    loop values
end

(* Every operation here is its unbound counterpart with [D.pp_error] supplied, so
   values built through the functor and values built directly are the same
   values. Only operations that take a printer appear; the rest stay in [Err]. *)
module Make (D : Domain) : S with type error = D.error = struct
  type error = D.error

  let pp_error = D.pp_error
  let pp pp_value ppf result = pp pp_value D.pp_error ppf result
  let fail ?pos kind = fail ?pos ~pp_error:D.pp_error kind
  let of_option ?pos kind option = of_option ?pos ~pp_error:D.pp_error kind option
  let map_none ?pos ~error option = map_none ?pos ~pp_error:D.pp_error ~error option
  let guard ?pos ~error condition = guard ?pos ~pp_error:D.pp_error ~error condition
  let map_error ?pos f result = map_error ?pos ~pp_error:D.pp_error f result
  let mark_error ?pos action result = mark_error ?pos ~pp_error:D.pp_error action result
  let protect ?pos ~catch f = protect ?pos ~pp_error:D.pp_error ~catch f
  let import ?pos f result = import ?pos ~pp_error:D.pp_error f result
  let export ?pos result = export ?pos ~pp_error:D.pp_error result
  let to_exn ?pos error = to_exn ?pos ~pp_error:D.pp_error error
  let export_exn ?pos result = export_exn ?pos ~pp_error:D.pp_error result
  let raise_error ?pos error = raise_error ?pos ~pp_error:D.pp_error error
  let or_raise ?pos result = or_raise ?pos ~pp_error:D.pp_error result
  let with_escape f = Escape.with_escape f
  let throw token ?pos kind = Escape.throw token ?pos ~pp_error:D.pp_error kind

  module Error = struct
    let make ?pos kind = Error.make ?pos ~pp_error:D.pp_error kind
    let map_kind ?pos f error = Error.map_kind ?pos ~pp_error:D.pp_error f error
    let pp ppf error = Error.pp D.pp_error ppf error
    let pp_kind ppf error = Error.pp_kind D.pp_error ppf error
  end

  module List = struct
    let map2 ?pos ~unequal_lengths f left right = List.map2 ?pos ~pp_error:D.pp_error ~unequal_lengths f left right
    let iter2 ?pos ~unequal_lengths f left right = List.iter2 ?pos ~pp_error:D.pp_error ~unequal_lengths f left right
  end
end

module Syntax = struct
  let ( let* ) = bind
  let ( let+ ) result f = map f result
  let ( >>= ) = bind
  let ( >>| ) result f = map f result
end

module Accum = struct
  type 'e errors = 'e Error.t list

  let pp_errors pp_error ppf = function
    | [] -> ()
    | error :: errors ->
        Format.fprintf ppf "@[<v>%a" (Error.pp pp_error) error;
        Stdlib.List.iter (fun error -> Format.fprintf ppf "@,%a" (Error.pp pp_error) error) errors;
        Format.fprintf ppf "@]"

  (* The batch wrapper takes no [pp_error]: each element failure already
     dispatched its own observation, with its own domain printer, at its own
     detection site; the wrapper therefore records neither a [Detect] event nor
     a call stack, only the position of the batch. *)
  let collected ?pos errors_rev =
    let origin = Origin.make ?source:(Option.map Source.of_pos pos) () in
    Error (Error.make_at ~origin (Stdlib.List.rev errors_rev))

  let map ?pos f values =
    let rec loop mapped errors_rev = function
      | [] -> ( match errors_rev with [] -> Ok (Stdlib.List.rev mapped) | _ -> collected ?pos errors_rev)
      | value :: values -> (
          match f value with
          | Ok mapped_value -> loop (mapped_value :: mapped) errors_rev values
          | Error error -> loop mapped (error :: errors_rev) values)
    in
    loop [] [] values

  let iter ?pos f values =
    let rec loop errors_rev = function
      | [] -> ( match errors_rev with [] -> Ok () | _ -> collected ?pos errors_rev)
      | value :: values -> (
          match f value with Ok () -> loop errors_rev values | Error error -> loop (error :: errors_rev) values)
    in
    loop [] values

  let all ?pos results = map ?pos (fun result -> result) results

  let both ?pos left right =
    match (left, right) with
    | Ok left, Ok right -> Ok (left, right)
    | Error left, Error right -> collected ?pos [ right; left ]
    | Error error, Ok _ | Ok _, Error error -> collected ?pos [ error ]

  let lift = function Ok value -> Ok value | Error error -> Error (Error.with_kind_untraced [ error ] error)

  (* Joining two batches adds nothing to either: no event, no dispatch. With
     both failed, the batch is the failures of the left then the right. *)
  let join left right =
    match (left, right) with
    | Ok left, Ok right -> Ok (left, right)
    | Error batch, Ok _ | Ok _, Error batch -> Error batch
    | Error left, Error right -> Error (Error.make_at ~origin:None (Error.kind left @ Error.kind right))

  module Syntax = struct
    let ( let+ ) result f = match result with Ok value -> Ok (f value) | Error batch -> Error batch
    let ( and+ ) = join
  end

  let fold_errors combine = function
    | Ok value -> Ok value
    | Error batch -> (
        match Error.kind batch with
        | first :: _ as errors -> Error (Error.map_kind_untraced (fun _ -> combine errors) first)
        | [] -> Error (Error.map_kind_untraced combine batch))
end
