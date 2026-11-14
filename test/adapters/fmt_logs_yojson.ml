type error = [ `Missing of string | `Remote of string ]

let has_prefix ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length && String.sub value 0 prefix_length = prefix

let has_suffix ~suffix value =
  let suffix_length = String.length suffix in
  let value_length = String.length value in
  value_length >= suffix_length && String.sub value (value_length - suffix_length) suffix_length = suffix

let pp_error ppf = function
  | `Missing field -> Fmt.pf ppf "missing field %S" field
  | `Remote message -> Fmt.pf ppf "remote error %S" message

let config =
  Err.Config.make
    ~actions:(Err.Action.Set.of_list [ Err.Action.Import; Err.Action.Export ])
    ~backtrace:Err.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:64
  |> Result.get_ok

let contains_substring text substring =
  let text_length = String.length text and substring_length = String.length substring in
  let rec loop offset =
    offset + substring_length <= text_length
    && (String.sub text offset substring_length = substring || loop (offset + 1))
  in
  substring_length = 0 || loop 0

let export_wire (result : (int, error Err.Error.t) result) =
  match Err.mark_error `Export result with
  | Ok value -> `Assoc [ ("ok", `Bool true); ("value", `Int value) ]
  | Error error -> (
      match Err.Error.kind error with
      | `Missing field ->
          `Assoc
            [
              ("ok", `Bool false);
              ("code", `String "missing-field");
              ("message", `String (Fmt.str "%a" pp_error (`Missing field)));
              ("details", `Assoc [ ("field", `String field) ]);
              ("traceId", `Null);
            ]
      | `Remote message ->
          `Assoc
            [
              ("ok", `Bool false);
              ("code", `String "remote");
              ("message", `String message);
              ("details", `Null);
              ("traceId", `Null);
            ])

let import_wire wire : (unit, error Err.Error.t) result =
  match wire with
  | `Assoc fields -> (
      match List.assoc_opt "code" fields with
      | Some (`String "remote") ->
          let message =
            match List.assoc_opt "message" fields with Some (`String message) -> message | _ -> "unknown"
          in
          Err.import (fun message -> `Remote message) (Error message)
      | _ -> invalid_arg "unsupported wire error")
  | _ -> invalid_arg "wire error must be an object"

let () =
  Err.Config.set config;
  let failure = Err.fail ~pos:("secret/server.ml", 9, 1, 7) (`Missing "token") in
  let rendered = Fmt.str "@[<v>before@,%a@,after@]" (Err.Error.pp pp_error) (Result.get_error failure) in
  assert (has_prefix ~prefix:"before\nmissing field" rendered);
  assert (has_suffix ~suffix:"after" rendered);
  let wire = export_wire failure in
  let json = Yojson.Safe.to_string wire in
  assert (contains_substring json "missing-field");
  assert (not (contains_substring json "secret"));
  assert (not (contains_substring json "server.ml"));
  let imported = import_wire (`Assoc [ ("code", `String "remote"); ("message", `String "offline") ]) in
  let imported_error = Result.get_error imported in
  assert (Err.Error.kind imported_error = `Remote "offline");
  assert (Err.Error.events imported_error |> List.map Err.Event.action = [ Err.Action.Import ]);
  let buffer = Buffer.create 128 in
  let formatter = Format.formatter_of_buffer buffer in
  let previous_reporter = Logs.reporter () in
  let previous_level = Logs.level () in
  Logs.set_reporter (Logs.format_reporter ~dst:formatter ());
  Logs.set_level (Some Logs.Error);
  let observations = ref 0 in
  let monitor =
    Err.Monitor.install ~actions:(Err.Action.Set.of_list [ Err.Action.Export ]) (fun observation ->
        incr observations;
        Logs.err (fun message -> message "%a" Err.Observation.pp observation))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Err.Monitor.remove monitor);
      Logs.set_reporter previous_reporter;
      Logs.set_level previous_level)
    (fun () ->
      ignore (Err.to_exn ~pp_error (Result.get_error (Err.fail (`Remote "logger"))));
      Format.pp_print_flush formatter ());
  assert (!observations = 1);
  assert (contains_substring (Buffer.contents buffer) "export")
