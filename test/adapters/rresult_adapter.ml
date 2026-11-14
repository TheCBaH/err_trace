let config =
  Err.Config.make
    ~actions:(Err.Action.Set.of_list [ Err.Action.Import; Err.Action.Export ])
    ~backtrace:Err.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:0
  |> Result.get_ok

let of_rresult result = Err.import Fun.id result
let to_rresult result = Err.export result
let actions error = Err.Error.events error |> List.map Err.Event.action

let () =
  Err.Config.set config;
  let direct : (int, string Err.Error.t) Rresult.R.t = Err.return 1 in
  assert (direct = Ok 1);
  let imported = of_rresult (Error "foreign") in
  let imported_error = Result.get_error imported in
  assert (Err.Error.kind imported_error = "foreign");
  assert (actions imported_error = [ Err.Action.Import ]);
  assert (to_rresult imported = Error "foreign")
