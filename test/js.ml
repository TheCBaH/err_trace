open Js_of_ocaml

type error = Portable_checks.error

let pp_error = Portable_checks.pp_error
let assert_true condition = if not condition then failwith "assertion failed"
let check name condition = if not condition then failwith ("assertion failed: " ^ name)
let field object_ name = Js.Unsafe.get object_ name

let public_error message =
  Js.Unsafe.obj
    [|
      ("code", Js.Unsafe.inject (Js.string "expected"));
      ("message", Js.Unsafe.inject (Js.string message));
      ("details", Js.Unsafe.inject Js.null);
      ("traceId", Js.Unsafe.inject Js.null);
    |]

let outcome (result : ('a, error Err_trace.Error.t) result) =
  match result with
  | Ok value -> Js.Unsafe.obj [| ("ok", Js.Unsafe.inject Js._true); ("value", Js.Unsafe.inject value) |]
  | Error error ->
      let message = Format.asprintf "%a" pp_error (Err_trace.Error.kind error) in
      Js.Unsafe.obj [| ("ok", Js.Unsafe.inject Js._false); ("error", Js.Unsafe.inject (public_error message)) |]

let import_javascript_error ~pos error =
  let stack =
    match Js.Js_error.stack error with
    | None -> None
    | Some stack -> Some (Err_trace.Stack.of_external ~runtime:"JavaScript" ~stack)
  in
  let origin = Err_trace.Origin.make ~source:(Err_trace.Source.of_pos pos) ?stack () in
  Error (Err_trace.Error.make_at ~origin (`Expected (Js.Js_error.message error))) |> Err_trace.mark_error ~pos `Catch

let protect_javascript ~pos ~expected f =
  try Ok (f ())
  with Js.Js_error.Exn error ->
    if expected error then import_javascript_error ~pos error else Js.Js_error.raise_ error

let export_javascript_error error =
  let error = Err_trace.mark_error `Export (Error error) |> Result.get_error in
  let message = Format.asprintf "%a" (Err_trace.Error.pp pp_error) error in
  new%js Js.error_constr (Js.string message)

let settle_expected promise =
  Promise.then_ ~on_error:(fun reason -> Promise.reject reason) (fun result -> Promise.resolve (outcome result)) promise

let config = Portable_checks.config

let () =
  Err_trace.Config.set
    (config (Err_trace.Action.Set.of_list [ Err_trace.Action.Catch; Err_trace.Action.Export; Err_trace.Action.Map ]) 8);
  let success = outcome (Ok 7) in
  assert_true (Js.to_bool (field success "ok"));
  assert_true ((field success "value" : int) = 7);
  let failure = outcome (Err_trace.fail (`Expected "domain")) in
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
  Portable_checks.check_imported ~check imported;
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
  Portable_checks.run ~check;
  let expected_promise =
    Promise.resolve (Err_trace.fail (`Expected "promise"))
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
