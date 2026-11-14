type diagnostic = [ `Compiler of Location.t * string ]

let has_prefix ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length && String.sub value 0 prefix_length = prefix

let has_suffix ~suffix value =
  let suffix_length = String.length suffix in
  let value_length = String.length value in
  value_length >= suffix_length && String.sub value (value_length - suffix_length) suffix_length = suffix

let source_of_location location =
  let start = location.Location.loc_start in
  let finish = location.Location.loc_end in
  Err.Source.of_pos
    ( start.Lexing.pos_fname,
      start.Lexing.pos_lnum,
      start.Lexing.pos_cnum - start.Lexing.pos_bol,
      finish.Lexing.pos_cnum - finish.Lexing.pos_bol )

let import location message : diagnostic Err.Error.t =
  let origin = Err.Origin.make ~source:(source_of_location location) () in
  Err.Error.make_at ~origin (`Compiler (location, message))

let export error =
  let error = Err.mark_error `Export (Error error) |> Result.get_error in
  match Err.Error.kind error with
  | `Compiler (location, message) -> Format.asprintf "%a: %s" Location.print_loc location message

let () =
  let config =
    Err.Config.make
      ~actions:(Err.Action.Set.of_list [ Err.Action.Export ])
      ~backtrace:Err.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:0
    |> Result.get_ok
  in
  Err.Config.set config;
  let start = { Lexing.pos_fname = "parser.ml"; pos_lnum = 4; pos_bol = 20; pos_cnum = 23 } in
  let location = { Location.loc_start = start; loc_end = { start with pos_cnum = 28 }; loc_ghost = false } in
  let error = import location "unexpected token" in
  let origin = Option.get (Err.Error.origin error) in
  assert (Err.Origin.source origin <> None);
  let rendered = export error in
  assert (has_prefix ~prefix:"File \"parser.ml\", line 4" rendered);
  assert (has_suffix ~suffix:"unexpected token" rendered)
