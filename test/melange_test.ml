type error = [ `Expected of string ]
type outcome = Obj.t Js.Dict.t

external make_error : string -> Js.Exn.t = "Error" [@@mel.new]

let pp_error ppf = function `Expected message -> Format.pp_print_string ppf message
let assert_true condition = if not condition then failwith "assertion failed"
let boxed value = (Obj.magic value : Obj.t)

let outcome = function
  | Ok value -> Js.Dict.fromList [ ("ok", boxed true); ("value", boxed value) ]
  | Error error ->
      let message = Format.asprintf "%a" pp_error (Err.Error.kind error) in
      let public =
        Js.Dict.fromList
          [ ("code", boxed "expected"); ("message", boxed message); ("details", boxed None); ("traceId", boxed None) ]
      in
      Js.Dict.fromList [ ("ok", boxed false); ("error", boxed public) ]

let get dictionary name = Js.Dict.unsafeGet dictionary name

let import_javascript_error ~pos error =
  let stack =
    match Js.Exn.stack error with
    | None -> None
    | Some stack -> Some (Err.Stack.of_external ~runtime:"JavaScript" ~stack)
  in
  let message = Option.value ~default:"JavaScript error" (Js.Exn.message error) in
  let origin = Err.Origin.make ~source:(Err.Source.of_pos pos) ?stack () in
  Error (Err.Error.make_at ~origin (`Expected message)) |> Err.mark_error ~pos Err.Action.Catch

let protect_javascript ~pos ~expected f =
  try Ok (f ())
  with exn -> (
    match Js.Exn.asJsExn exn with
    | Some error when expected error -> import_javascript_error ~pos error
    | Some _ | None -> raise exn)

let export_javascript_error error =
  let error = Err.mark_error Err.Action.Export (Error error) |> Result.get_error in
  make_error (Format.asprintf "%a" (Err.Error.pp pp_error) error)

let settle_expected promise = Js.Promise.then_ (fun result -> Js.Promise.resolve (outcome result)) promise

let config actions max_events =
  Err.Config.make ~actions ~backtrace:Err.Config.Never ~max_events ~max_frames:0 ~max_external_bytes:4_096
  |> Result.get_ok

let () =
  Err.Config.set (config (Err.Action.Set.of_list [ Err.Action.Catch; Err.Action.Export; Err.Action.Map ]) 8);
  let success = outcome (Ok 7) in
  assert_true (Obj.magic (get success "ok") = true);
  assert_true (Obj.magic (get success "value") = 7);
  let failure = outcome (Err.fail (`Expected "domain")) in
  assert_true (Obj.magic (get failure "ok") = false);
  let public : outcome = Obj.magic (get failure "error") in
  assert_true (Obj.magic (get public "code") = "expected");
  assert_true (Obj.magic (get public "message") = "domain");
  let imported =
    protect_javascript ~pos:("adapter.ml", 4, 2, 12)
      ~expected:(fun error -> Js.Exn.message error = Some "native")
      (fun () -> Js.Exn.raiseError "native")
    |> Result.get_error
  in
  assert_true (Err.Error.kind imported = `Expected "native");
  assert_true
    (match Err.Error.origin imported with
    | None -> false
    | Some origin -> (
        Err.Origin.source origin <> None
        && match Err.Origin.stack origin with None -> true | Some stack -> Err.Stack.is_available stack));
  assert_true
    (try
       ignore
         (protect_javascript ~pos:("adapter.ml", 5, 0, 3)
            ~expected:(fun _ -> false)
            (fun () -> Js.Exn.raiseError "escape"));
       false
     with exn -> ( match Js.Exn.asJsExn exn with Some error -> Js.Exn.message error = Some "escape" | None -> false));
  let native_export = export_javascript_error imported in
  assert_true (Js.Exn.name native_export = Some "Error");
  assert_true (Js.Exn.message native_export <> None);
  let ocaml_export = Err.to_exn ~pp_error imported in
  assert_true (String.length (Printexc.to_string ocaml_export) > 0);
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
  assert_true (List.rev !calls = [ "first"; "failing"; "first" ]);
  assert_true (Err.Error.events (Result.get_error mapped) = [] && Err.Error.dropped_events (Result.get_error mapped) = 1);
  (* Escape relies on a locally generated exception per [with_escape] call, and
     Accum on a bounded fold; both are worth exercising on this backend, whose
     exception representation is not the native one. *)
  Err.Config.set (config Err.Action.Set.all 8);
  let escaped =
    Err.Escape.with_escape (fun outer ->
        let inner = Err.Escape.with_escape (fun inner -> Err.Escape.throw inner (`Expected "inner")) in
        assert_true (match inner with Error error -> Err.Error.kind error = `Expected "inner" | Ok _ -> false);
        let _ : (int, error Err.Error.t) result =
          Err.Escape.with_escape (fun _ -> Err.Escape.throw outer (`Expected "outer"))
        in
        0)
  in
  assert_true (match escaped with Error error -> Err.Error.kind error = `Expected "outer" | Ok _ -> false);
  assert_true
    (try
       ignore (Err.Escape.with_escape (fun _ -> failwith "foreign"));
       false
     with Failure message -> message = "foreign");
  let bridged = Err.Escape.with_escape (fun token -> Err.Escape.or_throw token (Err.fail (`Expected "bridge")) + 1) in
  assert_true (match bridged with Error error -> Err.Error.kind error = `Expected "bridge" | Ok _ -> false);
  let leaked = ref None in
  let _ =
    Err.Escape.with_escape (fun token ->
        leaked := Some token;
        0)
  in
  assert_true
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
  assert_true (match accumulated with Error error -> List.length (Err.Error.kind error) = 2 | Ok _ -> false);
  assert_true
    (match Err.Accum.map (fun value -> Err.return value) [ 1; 2 ] with
    | Ok values -> values = [ 1; 2 ]
    | Error _ -> false);
  (* Re-raising a foreign exception must surface that exception, not a failure
     of the backtrace machinery. This backend does not implement
     [caml_restore_raw_backtrace], so it only holds because the library
     reattaches a backtrace solely when it has resolvable frames. Exercising it
     needs a policy that captures stacks, as [Config.with_stacks] does. *)
  let capturing =
    Err.Config.make ~actions:Err.Action.Set.all ~backtrace:Err.Config.Origin ~max_events:8 ~max_frames:8
      ~max_external_bytes:0
    |> Result.get_ok
  in
  Err.Config.set capturing;
  assert_true
    (match Err.Escape.with_escape (fun _ -> failwith "foreign") with
    | exception Failure message -> message = "foreign"
    | exception _ -> false
    | Ok _ | Error _ -> false);
  assert_true
    (match Err.protect ~catch:(fun _ -> None) (fun () -> failwith "foreign") with
    | exception Failure message -> message = "foreign"
    | exception _ -> false
    | Ok _ | Error _ -> false);
  let expected_promise =
    Js.Promise.resolve (Err.fail (`Expected "promise"))
    |> settle_expected
    |> Js.Promise.then_ (fun result ->
        assert_true (Obj.magic (get result "ok") = false);
        Js.Promise.resolve ())
  in
  let rejection_seen = ref false in
  let unknown = Js.Promise.reject (Failure "unknown") |> settle_expected in
  let unknown =
    Js.Promise.catch
      (fun _ ->
        rejection_seen := true;
        Js.Promise.resolve (outcome (Ok ())))
      unknown
    |> Js.Promise.then_ (fun _ -> Js.Promise.resolve ())
  in
  ignore
    (Js.Promise.all2 (expected_promise, unknown)
    |> Js.Promise.then_ (fun _ ->
        assert_true !rejection_seen;
        Js.log "Melange adapter conformance: ok";
        Js.Promise.resolve ()))
