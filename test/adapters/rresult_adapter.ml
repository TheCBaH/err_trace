let config =
  Err_trace.Config.make
    ~actions:(Err_trace.Action.Set.of_list [ Err_trace.Action.Import; Err_trace.Action.Export ])
    ~backtrace:Err_trace.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:0
  |> Result.get_ok

let of_rresult result = Err_trace.import Fun.id result
let to_rresult result = Err_trace.export result
let actions error = Err_trace.Error.events error |> List.map Err_trace.Event.action

let () =
  Err_trace.Config.set config;
  let direct : (int, string Err_trace.Error.t) Rresult.R.t = Err_trace.return 1 in
  assert (direct = Ok 1);
  let imported = of_rresult (Error "foreign") in
  let imported_error = Result.get_error imported in
  assert (Err_trace.Error.kind imported_error = "foreign");
  assert (actions imported_error = [ Err_trace.Action.Import ]);
  assert (to_rresult imported = Error "foreign")
