(* Backend-independent checks, shared by source with the native,
   js_of_ocaml and Melange tests. Depends only on [Err] and the Stdlib. *)

type error = [ `Expected of string ]

let pp_error ppf = function `Expected message -> Format.pp_print_string ppf message

let config actions max_events =
  Err.Config.make ~actions ~backtrace:Err.Config.Never ~max_events ~max_frames:0 ~max_external_bytes:4_096
  |> Result.get_ok

(* An error imported from a foreign exception carrying message "native". *)
let check_imported ~(check : string -> bool -> unit) (imported : error Err.Error.t) =
  check "imported kind" (Err.Error.kind imported = `Expected "native");
  check "imported origin"
    (match Err.Error.origin imported with
    | None -> false
    | Some origin -> (
        Err.Origin.source origin <> None
        && match Err.Origin.stack origin with None -> true | Some stack -> Err.Stack.is_available stack));
  let ocaml_export = Err.to_exn ~pp_error imported in
  check "to_exn printable" (String.length (Printexc.to_string ocaml_export) > 0)

let run ~(check : string -> bool -> unit) =
  Err.Config.set (config (Err.Action.Set.of_list [ Err.Action.Map ]) 0);
  let calls = ref [] in
  let first = Err.Monitor.install (fun _ -> calls := "first" :: !calls) in
  let failing =
    Err.Monitor.install (fun _ ->
        calls := "failing" :: !calls;
        failwith "logger")
  in
  let mapped = Err.fail (`Expected "monitor") |> Err.map_error Fun.id in
  ignore (Err.map_error Fun.id mapped);
  ignore (Err.Monitor.remove first);
  ignore (Err.Monitor.remove failing);
  check "monitor calls" (List.rev !calls = [ "first"; "failing"; "first" ]);
  check "monitor events dropped"
    (Err.Error.events (Result.get_error mapped) = [] && Err.Error.dropped_events (Result.get_error mapped) = 1);
  (* Escape relies on a locally generated exception per [with_escape] call, and
     Accum on a bounded fold; both are worth exercising on backends whose
     exception representation is not the native one. *)
  Err.Config.set (config Err.Action.Set.all 8);
  let escaped =
    Err.Escape.with_escape (fun outer ->
        let inner = Err.Escape.with_escape (fun inner -> Err.Escape.throw inner (`Expected "inner")) in
        check "escape inner"
          (match inner with Error error -> Err.Error.kind error = `Expected "inner" | Ok _ -> false);
        let _ : (int, error Err.Error.t) result =
          Err.Escape.with_escape (fun _ -> Err.Escape.throw outer (`Expected "outer"))
        in
        0)
  in
  check "escape outer" (match escaped with Error error -> Err.Error.kind error = `Expected "outer" | Ok _ -> false);
  check "escape foreign exception"
    (try
       ignore (Err.Escape.with_escape (fun _ -> failwith "foreign"));
       false
     with Failure message -> message = "foreign");
  let bridged = Err.Escape.with_escape (fun token -> Err.Escape.or_throw token (Err.fail (`Expected "bridge")) + 1) in
  check "escape or_throw"
    (match bridged with Error error -> Err.Error.kind error = `Expected "bridge" | Ok _ -> false);
  let leaked = ref None in
  let _ =
    Err.Escape.with_escape (fun token ->
        leaked := Some token;
        0)
  in
  check "escape after exit"
    (match !leaked with
    | None -> false
    | Some token -> (
        try
          ignore (Err.Escape.throw token (`Expected "leaked"));
          false
        with Err.Escape.Escaped_after_exit _ -> true));
  let accumulated =
    Err.Accum.map
      (fun value -> if value mod 2 = 0 then Err.fail (`Expected "even") else Err.return value)
      [ 1; 2; 3; 4 ]
  in
  check "accum errors" (match accumulated with Error error -> List.length (Err.Error.kind error) = 2 | Ok _ -> false);
  check "accum ok"
    (match Err.Accum.map (fun value -> Err.return value) [ 1; 2 ] with
    | Ok values -> values = [ 1; 2 ]
    | Error _ -> false);
  (* Re-raising a foreign exception must surface that exception, not a failure
     of the backtrace machinery. JavaScript backends do not implement
     [caml_restore_raw_backtrace], so it only holds because the library
     reattaches a backtrace solely when it has resolvable frames. Exercising it
     needs a policy that captures stacks, as [Config.with_stacks] does. *)
  let capturing =
    Err.Config.make ~actions:Err.Action.Set.all ~backtrace:Err.Config.Origin ~max_events:8 ~max_frames:8
      ~max_external_bytes:0
    |> Result.get_ok
  in
  Err.Config.set capturing;
  check "reraise escape"
    (match Err.Escape.with_escape (fun _ -> failwith "foreign") with
    | exception Failure message -> message = "foreign"
    | exception _ -> false
    | Ok _ | Error _ -> false);
  check "reraise protect"
    (match Err.protect ~catch:(fun _ -> None) (fun () -> failwith "foreign") with
    | exception Failure message -> message = "foreign"
    | exception _ -> false
    | Ok _ | Error _ -> false)
