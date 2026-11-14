type error = Portable_checks.error
type outcome = Obj.t Js.Dict.t

external make_error : string -> Js.Exn.t = "Error" [@@mel.new]

let pp_error = Portable_checks.pp_error
let assert_true condition = if not condition then failwith "assertion failed"
let check name condition = if not condition then failwith ("assertion failed: " ^ name)
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
  Error (Err.Error.make_at ~origin (`Expected message)) |> Err.mark_error ~pos `Catch

let protect_javascript ~pos ~expected f =
  try Ok (f ())
  with exn -> (
    match Js.Exn.asJsExn exn with
    | Some error when expected error -> import_javascript_error ~pos error
    | Some _ | None -> raise exn)

let export_javascript_error error =
  let error = Err.mark_error `Export (Error error) |> Result.get_error in
  make_error (Format.asprintf "%a" (Err.Error.pp pp_error) error)

let settle_expected promise = Js.Promise.then_ (fun result -> Js.Promise.resolve (outcome result)) promise
let config = Portable_checks.config

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
  Portable_checks.check_imported ~check imported;
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
  Portable_checks.run ~check;
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
