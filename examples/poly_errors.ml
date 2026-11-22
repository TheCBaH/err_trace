(** [Base] is a shared infrastructure error domain. Modules A and B both include these tags directly, so a timeout need
    not be wrapped at every internal boundary. *)
module Base = struct
  type timeout = { operation : string; seconds : int }
  type error = [ `Cancelled | `Timeout of timeout ]

  let pp_error ppf = function
    | `Cancelled -> Format.pp_print_string ppf "operation cancelled"
    | `Timeout { operation; seconds } -> Format.fprintf ppf "%s timed out after %ds" operation seconds
end

(** Module A owns the storage domain. Its public [error] type is the union of shared Base errors and errors that only
    make sense to A. *)
module A = struct
  type missing_record = { table : string; key : int }
  type malformed_record = { table : string; key : int; field : string; value : string }
  type local_error = [ `Malformed_record of malformed_record | `Missing_record of missing_record ]
  type error = [ Base.error | local_error ]

  let pp_error ppf = function
    | #Base.error as error -> Base.pp_error ppf error
    | `Malformed_record { table; key; field; value } ->
        Format.fprintf ppf "%s record %d has invalid %s=%S" table key field value
    | `Missing_record ({ table; key } : missing_record) -> Format.fprintf ppf "%s record %d is missing" table key

  let fetch_user user_id : (string, error) Err_trace.t =
    (* [__POS__] is an OCaml compiler constant, so this remains portable while
       recording the exact source coordinate at which A detects the error.
       Supplying [pp_error] does not log here or retain a printer in the error;
       it lets a synchronously installed monitor render this observation. *)
    if user_id = 0 then
      Err_trace.fail ~pos:__POS__ ~pp_error (`Timeout ({ operation = "users lookup"; seconds = 2 } : Base.timeout))
    else Err_trace.fail ~pos:__POS__ ~pp_error (`Missing_record { table = "users"; key = user_id })
end

(** Module B owns the profile domain. It calls A, but does not expose every A-specific error as one of its own top-level
    tags. *)
module B = struct
  type error = [ Base.error | `A of A.local_error | `Invalid_user_id of int | `Unsupported_plan of string ]

  let pp_error ppf = function
    | #Base.error as error -> Base.pp_error ppf error
    | `A error -> Format.fprintf ppf "profile unavailable: %a" A.pp_error error
    | `Invalid_user_id id -> Format.fprintf ppf "invalid user id %d" id
    | `Unsupported_plan plan -> Format.fprintf ppf "unsupported plan %S" plan

  let error_of_a : A.error -> error = function
    (* Base errors belong to both domains, so preserve the shared tag. *)
    | `Cancelled -> `Cancelled
    | `Timeout timeout -> `Timeout timeout
    (* A-local errors cross a real domain boundary and are wrapped by B. *)
    | #A.local_error as error -> `A error

  let load_profile user_id : (string, error) Err_trace.t =
    A.fetch_user user_id
    (* [map_error] changes only the typed payload, retains A's detection
       origin, and records this semantic Map boundary. B supplies its printer
       because the payload now belongs to B's error domain. *)
    |> Err_trace.map_error ~pos:__POS__ ~pp_error error_of_a
end

let config ~backtrace =
  Err_trace.Config.make
    ~actions:(Err_trace.Action.Set.of_list [ Err_trace.Action.Detect; Err_trace.Action.Map ])
    ~backtrace ~max_events:8 ~max_frames:8 ~max_external_bytes:0
  |> Result.get_ok

let handle user_id =
  match B.load_profile user_id with
  | Ok profile -> Format.printf "loaded: %s@." profile
  | Error error -> (
      (* B's caller still receives structured data. It can distinguish a
         shared timeout from a wrapped A-specific missing-record error. *)
      match Err_trace.Error.kind error with
      | `Timeout { operation; _ } -> Format.printf "[handled] retry %s later@." operation
      | `A (`Missing_record ({ table; key } : A.missing_record)) ->
          Format.printf "[handled] provision %s record %d, then retry@." table key
      | `A (`Malformed_record _) | `Cancelled | `Invalid_user_id _ | `Unsupported_plan _ ->
          Format.printf "[handled] do not retry@.")

let install_logging_monitor () =
  (* Logging is an application concern rather than a side effect hidden in A
     or B. This monitor subscribes once to both transitions. Each operation
     supplies the printer for its current typed domain, so [Observation.pp]
     renders the complete error as it looked at that exact boundary. *)
  Err_trace.Monitor.install
    ~actions:(Err_trace.Action.Set.of_list [ Err_trace.Action.Detect; Err_trace.Action.Map ])
    (fun observation ->
      let action = Err_trace.Observation.event observation |> Err_trace.Event.action in
      Format.printf "@[<v>[monitor] %a@,%a@]@." Err_trace.Action.pp action Err_trace.Observation.pp observation)

let show_automatic_origin () =
  (* Without [~pos], Config.Origin asks Err_trace to capture the current runtime's
     stack. Native OCaml normally provides useful frames; JavaScript backends
     may only provide an unavailable-stack marker. The accessors are portable,
     so the cram test checks the stable facts rather than printing frames. Use
     [Err_trace.Origin.pp] when backend-specific stack text is appropriate. *)
  Err_trace.Config.set (config ~backtrace:Err_trace.Config.Origin);
  let error = Err_trace.fail `Cancelled |> Result.get_error in
  let origin = Err_trace.Error.origin error |> Option.get in
  Format.printf "[origin without ~pos] explicit-source=%b automatic-stack=%b@."
    (Err_trace.Origin.source origin <> None)
    (Err_trace.Origin.stack origin <> None)

let () =
  (* Explicit locations plus no automatic stack make the main logs identical
     for bytecode, optimized native code, js_of_ocaml, and Melange. *)
  Err_trace.Config.set (config ~backtrace:Err_trace.Config.Never);
  let monitor = install_logging_monitor () in
  handle 42;
  handle 0;
  (* The automatic-origin demonstration has no typed printer and intentionally
     runs after logging is uninstalled, keeping runtime stack text out of this
     cross-runtime cram test. *)
  ignore (Err_trace.Monitor.remove monitor);
  show_automatic_origin ()
