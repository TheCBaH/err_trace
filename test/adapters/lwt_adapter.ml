type error = [ `Foreign of string ]

let config =
  Err.Config.make
    ~actions:(Err.Action.Set.of_list [ Err.Action.Import; Err.Action.Export ])
    ~backtrace:Err.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:0
  |> Result.get_ok

let import (promise : ('a, string) result Lwt.t) : ('a, error Err.Error.t) result Lwt.t =
  Lwt.map (Result.map_error (fun message -> Err.Error.make (`Foreign message))) promise
  |> Lwt.map (Err.mark_error `Import)

let export promise = Lwt.map (Err.mark_error `Export) promise |> Lwt.map (Result.map_error Err.Error.kind)
let returned promise = match Lwt.state promise with Lwt.Return value -> value | _ -> assert false

let () =
  Err.Config.set config;
  assert (returned (import (Lwt.return (Ok 3))) = Ok 3);
  let imported = returned (import (Lwt.return (Error "remote"))) in
  let imported_error = Result.get_error imported in
  assert (Err.Error.kind imported_error = `Foreign "remote");
  assert (Err.Error.events imported_error |> List.map Err.Event.action = [ Err.Action.Import ]);
  assert (returned (export (Lwt.return imported)) = Error (`Foreign "remote"));
  let pending, _resolver = Lwt.task () in
  let adapted = Lwt.map (fun result -> result) pending in
  Lwt.cancel adapted;
  assert (match Lwt.state adapted with Lwt.Fail Lwt.Canceled -> true | _ -> false);
  let unexpected = Lwt.map (fun () -> failwith "unexpected") (Lwt.return ()) in
  assert (match Lwt.state unexpected with Lwt.Fail (Failure message) -> message = "unexpected" | _ -> false)
