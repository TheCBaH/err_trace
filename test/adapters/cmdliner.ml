let config =
  Err.Config.make
    ~actions:(Err.Action.Set.of_list [ Err.Action.Export ])
    ~backtrace:Err.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:0
  |> Result.get_ok

let has_prefix ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length && String.sub value 0 prefix_length = prefix

let to_cmdliner ~pp_error result =
  result |> Err.mark_error `Export
  |> Result.map_error (fun error -> `Msg (Format.asprintf "%a" (Err.Error.pp pp_error) error))

let () =
  Err.Config.set config;
  assert (to_cmdliner ~pp_error:Format.pp_print_string (Ok 1) = Ok 1);
  let converted = Err.fail ~pos:("cli.ml", 3, 2, 8) "invalid input" |> to_cmdliner ~pp_error:Format.pp_print_string in
  match converted with
  | Error (`Msg message) ->
      assert (has_prefix ~prefix:"invalid input" message);
      assert (not (String.contains message '\000'))
  | Ok _ -> assert false
