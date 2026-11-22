module Octez = Tezos_error_monad.Error_monad

type Octez.error += Err_trace_export of string

let () =
  Octez.register_error_kind `Temporary ~id:"err_trace.adapter" ~title:"err_trace adapter error"
    ~description:"An error exported from err_trace." ~pp:Format.pp_print_string
    Data_encoding.(obj1 (req "message" string))
    (function Err_trace_export message -> Some message | _ -> None)
    (fun message -> Err_trace_export message)

type error = [ `Octez_trace of Octez.error Octez.trace ]

let pp_error ppf = function `Octez_trace trace -> Octez.pp_print_trace ppf trace

let config =
  Err_trace.Config.make
    ~actions:(Err_trace.Action.Set.of_list [ Err_trace.Action.Import; Err_trace.Action.Export ])
    ~backtrace:Err_trace.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:0
  |> Result.get_ok

let import (result : 'a Octez.tzresult) : ('a, error Err_trace.Error.t) result =
  Err_trace.import (fun trace -> `Octez_trace trace) result

let export (result : ('a, error Err_trace.Error.t) result) : 'a Octez.tzresult =
  match Err_trace.mark_error `Export result with
  | Ok value -> Ok value
  | Error error ->
      let message = Format.asprintf "%a" (Err_trace.Error.pp pp_error) error in
      Octez.Result_syntax.tzfail (Err_trace_export message)

let () =
  Err_trace.Config.set config;
  assert (import (Ok 7) = Ok 7);
  assert (export (Ok 9) = Ok 9);
  let octez_failure = Octez.error_with "low-level failure" in
  let octez_failure = Octez.record_trace (Err_trace_export "context") octez_failure in
  let original_trace = Result.get_error octez_failure in
  let imported = import octez_failure in
  let imported_error = Result.get_error imported in
  assert (
    match Err_trace.Error.kind imported_error with `Octez_trace imported_trace -> imported_trace == original_trace);
  assert (Err_trace.Error.events imported_error |> List.map Err_trace.Event.action = [ Err_trace.Action.Import ]);
  let exported = export imported in
  let exported_trace = Result.get_error exported in
  let exported_message =
    Octez.TzTrace.fold
      (fun found error -> match (found, error) with None, Err_trace_export message -> Some message | _ -> found)
      None exported_trace
  in
  assert (match exported_message with Some message -> String.length message > 0 | None -> false);
  let info = Octez.find_info_of_error (Err_trace_export "registered") in
  assert (info.id = "err_trace.adapter")
