type error = [ `Foreign of string ]

let config =
  Err_trace.Config.make
    ~actions:(Err_trace.Action.Set.of_list [ Err_trace.Action.Import; Err_trace.Action.Export ])
    ~backtrace:Err_trace.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:0
  |> Result.get_ok

let import (promise : ('a, string) result Lwt.t) : ('a, error Err_trace.Error.t) result Lwt.t =
  Lwt.map (Err_trace.import (fun message -> `Foreign message)) promise

let export promise = Lwt.map Err_trace.export promise
let returned promise = match Lwt.state promise with Lwt.Return value -> value | _ -> assert false

let () =
  Err_trace.Config.set config;
  assert (returned (import (Lwt.return (Ok 3))) = Ok 3);
  let imported = returned (import (Lwt.return (Error "remote"))) in
  let imported_error = Result.get_error imported in
  assert (Err_trace.Error.kind imported_error = `Foreign "remote");
  assert (Err_trace.Error.events imported_error |> List.map Err_trace.Event.action = [ Err_trace.Action.Import ]);
  assert (returned (export (Lwt.return imported)) = Error (`Foreign "remote"));
  let pending, _resolver = Lwt.task () in
  let adapted = Lwt.map (fun result -> result) pending in
  Lwt.cancel adapted;
  assert (match Lwt.state adapted with Lwt.Fail Lwt.Canceled -> true | _ -> false);
  let unexpected = Lwt.map (fun () -> failwith "unexpected") (Lwt.return ()) in
  assert (match Lwt.state unexpected with Lwt.Fail (Failure message) -> message = "unexpected" | _ -> false)
