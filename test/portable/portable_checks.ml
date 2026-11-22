(* Backend-independent checks, shared by source with the native,
   js_of_ocaml and Melange tests. Depends only on [Err_trace] and the Stdlib. *)

type error = [ `Expected of string ]

let pp_error ppf = function `Expected message -> Format.pp_print_string ppf message

let config actions max_events =
  Err_trace.Config.make ~actions ~backtrace:Err_trace.Config.Never ~max_events ~max_frames:0 ~max_external_bytes:4_096
  |> Result.get_ok

(* An error imported from a foreign exception carrying message "native". *)
let check_imported ~(check : string -> bool -> unit) (imported : error Err_trace.Error.t) =
  check "imported kind" (Err_trace.Error.kind imported = `Expected "native");
  check "imported origin"
    (match Err_trace.Error.origin imported with
    | None -> false
    | Some origin -> (
        Err_trace.Origin.source origin <> None
        && match Err_trace.Origin.stack origin with None -> true | Some stack -> Err_trace.Stack.is_available stack));
  let ocaml_export = Err_trace.to_exn ~pp_error imported in
  check "to_exn printable" (String.length (Printexc.to_string ocaml_export) > 0)

let run ~(check : string -> bool -> unit) =
  Err_trace.Config.set (config (Err_trace.Action.Set.of_list [ Err_trace.Action.Map ]) 0);
  let calls = ref [] in
  let first = Err_trace.Monitor.install (fun _ -> calls := "first" :: !calls) in
  let failing =
    Err_trace.Monitor.install (fun _ ->
        calls := "failing" :: !calls;
        failwith "logger")
  in
  let mapped = Err_trace.fail (`Expected "monitor") |> Err_trace.map_error Fun.id in
  ignore (Err_trace.map_error Fun.id mapped);
  ignore (Err_trace.Monitor.remove first);
  ignore (Err_trace.Monitor.remove failing);
  check "monitor calls" (List.rev !calls = [ "first"; "failing"; "first" ]);
  check "monitor events dropped"
    (Err_trace.Error.events (Result.get_error mapped) = []
    && Err_trace.Error.dropped_events (Result.get_error mapped) = 1);
  (* Escape relies on a locally generated exception per [with_escape] call, and
     Accum on a bounded fold; both are worth exercising on backends whose
     exception representation is not the native one. *)
  Err_trace.Config.set (config Err_trace.Action.Set.all 8);
  let escaped =
    Err_trace.Escape.with_escape (fun outer ->
        let inner = Err_trace.Escape.with_escape (fun inner -> Err_trace.Escape.throw inner (`Expected "inner")) in
        check "escape inner"
          (match inner with Error error -> Err_trace.Error.kind error = `Expected "inner" | Ok _ -> false);
        let _ : (int, error Err_trace.Error.t) result =
          Err_trace.Escape.with_escape (fun _ -> Err_trace.Escape.throw outer (`Expected "outer"))
        in
        0)
  in
  check "escape outer"
    (match escaped with Error error -> Err_trace.Error.kind error = `Expected "outer" | Ok _ -> false);
  check "escape foreign exception"
    (try
       ignore (Err_trace.Escape.with_escape (fun _ -> failwith "foreign"));
       false
     with Failure message -> message = "foreign");
  let bridged =
    Err_trace.Escape.with_escape (fun token ->
        Err_trace.Escape.or_throw token (Err_trace.fail (`Expected "bridge")) + 1)
  in
  check "escape or_throw"
    (match bridged with Error error -> Err_trace.Error.kind error = `Expected "bridge" | Ok _ -> false);
  let leaked = ref None in
  let _ =
    Err_trace.Escape.with_escape (fun token ->
        leaked := Some token;
        0)
  in
  check "escape after exit"
    (match !leaked with
    | None -> false
    | Some token -> (
        try
          ignore (Err_trace.Escape.throw token (`Expected "leaked"));
          false
        with Err_trace.Escape.Escaped_after_exit _ -> true));
  let accumulated =
    Err_trace.Accum.map
      (fun value -> if value mod 2 = 0 then Err_trace.fail (`Expected "even") else Err_trace.return value)
      [ 1; 2; 3; 4 ]
  in
  check "accum errors"
    (match accumulated with Error error -> List.length (Err_trace.Error.kind error) = 2 | Ok _ -> false);
  check "accum ok"
    (match Err_trace.Accum.map (fun value -> Err_trace.return value) [ 1; 2 ] with
    | Ok values -> values = [ 1; 2 ]
    | Error _ -> false);
  (* Re-raising a foreign exception must surface that exception, not a failure
     of the backtrace machinery. JavaScript backends do not implement
     [caml_restore_raw_backtrace], so it only holds because the library
     reattaches a backtrace solely when it has resolvable frames. Exercising it
     needs a policy that captures stacks, as [Config.with_stacks] does. *)
  let capturing =
    Err_trace.Config.make ~actions:Err_trace.Action.Set.all ~backtrace:Err_trace.Config.Origin ~max_events:8
      ~max_frames:8 ~max_external_bytes:0
    |> Result.get_ok
  in
  Err_trace.Config.set capturing;
  check "reraise escape"
    (match Err_trace.Escape.with_escape (fun _ -> failwith "foreign") with
    | exception Failure message -> message = "foreign"
    | exception _ -> false
    | Ok _ | Error _ -> false);
  check "reraise protect"
    (match Err_trace.protect ~catch:(fun _ -> None) (fun () -> failwith "foreign") with
    | exception Failure message -> message = "foreign"
    | exception _ -> false
    | Ok _ | Error _ -> false)
