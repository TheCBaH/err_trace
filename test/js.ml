open Js_of_ocaml

type error = [ `Expected of string ]

let pp_error ppf = function `Expected message -> Format.pp_print_string ppf message
let assert_true condition = if not condition then failwith "assertion failed"
let field object_ name = Js.Unsafe.get object_ name

let public_error message =
  Js.Unsafe.obj
    [|
      ("code", Js.Unsafe.inject (Js.string "expected"));
      ("message", Js.Unsafe.inject (Js.string message));
      ("details", Js.Unsafe.inject Js.null);
      ("traceId", Js.Unsafe.inject Js.null);
    |]

let outcome (result : ('a, error Err.Error.t) result) =
  match result with
  | Ok value -> Js.Unsafe.obj [| ("ok", Js.Unsafe.inject Js._true); ("value", Js.Unsafe.inject value) |]
  | Error error ->
      let message = Format.asprintf "%a" pp_error (Err.Error.kind error) in
      Js.Unsafe.obj [| ("ok", Js.Unsafe.inject Js._false); ("error", Js.Unsafe.inject (public_error message)) |]

let import_javascript_error ~pos error =
  let stack =
    match Js.Js_error.stack error with
    | None -> None
    | Some stack -> Some (Err.Stack.of_external ~runtime:"JavaScript" ~stack)
  in
  let origin = Err.Origin.make ~source:(Err.Source.of_pos pos) ?stack () in
  Error (Err.Error.make_at ~origin (`Expected (Js.Js_error.message error))) |> Err.mark_error ~pos `Catch

let protect_javascript ~pos ~expected f =
  try Ok (f ())
  with Js.Js_error.Exn error ->
    if expected error then import_javascript_error ~pos error else Js.Js_error.raise_ error

let export_javascript_error error =
  let error = Err.mark_error `Export (Error error) |> Result.get_error in
  let message = Format.asprintf "%a" (Err.Error.pp pp_error) error in
  new%js Js.error_constr (Js.string message)

let settle_expected promise =
  Promise.then_ ~on_error:(fun reason -> Promise.reject reason) (fun result -> Promise.resolve (outcome result)) promise

let config actions max_events =
  Err.Config.make ~actions ~backtrace:Err.Config.Never ~max_events ~max_frames:0 ~max_external_bytes:4_096
  |> Result.get_ok

let () =
  Err.Config.set (config (Err.Action.Set.of_list [ Err.Action.Catch; Err.Action.Export; Err.Action.Map ]) 8);
  let success = outcome (Ok 7) in
  assert_true (Js.to_bool (field success "ok"));
  assert_true ((field success "value" : int) = 7);
  let failure = outcome (Err.fail (`Expected "domain")) in
  assert_true (not (Js.to_bool (field failure "ok")));
  let public = field failure "error" in
  assert_true (Js.to_string (field public "code") = "expected");
  assert_true (Js.to_string (field public "message") = "domain");
  let native = new%js Js.error_constr (Js.string "native") in
  let native = Js.Js_error.of_error native in
  let imported =
    protect_javascript ~pos:("adapter.ml", 4, 2, 12)
      ~expected:(fun error -> Js.Js_error.message error = "native")
      (fun () -> Js.Js_error.raise_ native)
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
            (fun () -> Js.Js_error.raise_ native));
       false
     with Js.Js_error.Exn error -> Js.Js_error.message error = "native");
  let native_export = export_javascript_error imported in
  assert_true (Js.instanceof native_export Js.error_constr);
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
    Promise.resolve (Err.fail (`Expected "promise"))
    |> settle_expected
    |> Promise.map (fun result -> assert_true (not (Js.to_bool (field result "ok"))))
  in
  let rejection_seen = ref false in
  let unknown = Promise.reject (Promise.error_of_exn (Failure "unknown")) in
  let unknown =
    settle_expected unknown
    |> Promise.catch (fun _ ->
        rejection_seen := true;
        Promise.resolve ())
  in
  ignore
    (Promise.all [ expected_promise; unknown ]
    |> Promise.map (fun _ ->
        assert_true !rejection_seen;
        print_endline "js_of_ocaml adapter conformance: ok"))
