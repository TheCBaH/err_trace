type read_error = [ `Read of string ]
type domain_write_error = [ `Write of string ]

let pp_read_error ppf = function `Read message -> Fmt.string ppf message
let pp_write_kind ppf = function `Write message -> Fmt.string ppf message

module Flow = struct
  type error = read_error Err_trace.Error.t

  let pp_error = Err_trace.Error.pp pp_read_error

  type write_error = [ `Closed | `Traced of domain_write_error Err_trace.Error.t ]

  let pp_write_error ppf = function
    | `Closed -> Mirage_flow.pp_write_error ppf `Closed
    | `Traced error -> Err_trace.Error.pp pp_write_kind ppf error

  type flow = {
    mutable reads : (Cstruct.t Mirage_flow.or_eof, error) result list;
    mutable closed : bool;
    mutable written : string list;
  }

  let read flow =
    match flow.reads with
    | result :: reads ->
        flow.reads <- reads;
        Lwt.return result
    | [] -> Lwt.return (Ok `Eof)

  let write flow buffer =
    if flow.closed then Lwt.return (Error `Closed)
    else (
      flow.written <- Cstruct.to_string buffer :: flow.written;
      Lwt.return (Ok ()))

  let writev flow buffers =
    if flow.closed then Lwt.return (Error `Closed)
    else (
      flow.written <- List.rev_append (List.rev_map Cstruct.to_string buffers) flow.written;
      Lwt.return (Ok ()))

  let shutdown flow mode =
    (match mode with `read -> flow.reads <- [] | `write | `read_write -> flow.closed <- true);
    Lwt.return_unit

  let close flow =
    flow.closed <- true;
    Lwt.return_unit
end

module _ : Mirage_flow.S = Flow

let returned promise = match Lwt.state promise with Lwt.Return value -> value | _ -> assert false

let () =
  let config =
    Err_trace.Config.make
      ~actions:(Err_trace.Action.Set.of_list [ Err_trace.Action.Import ])
      ~backtrace:Err_trace.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:0
    |> Result.get_ok
  in
  Err_trace.Config.set config;
  let imported_failure =
    Err_trace.import (fun message -> `Read message) (Error "transport") |> Result.map_error Fun.id
  in
  let flow =
    Flow.{ reads = [ Ok (`Data (Cstruct.of_string "hello")); imported_failure ]; closed = false; written = [] }
  in
  assert (match returned (Flow.read flow) with Ok (`Data bytes) -> Cstruct.to_string bytes = "hello" | _ -> false);
  let error = returned (Flow.read flow) |> Result.get_error in
  assert (Err_trace.Error.kind error = `Read "transport");
  assert (Err_trace.Error.events error |> List.map Err_trace.Event.action = [ Err_trace.Action.Import ]);
  assert (returned (Flow.write flow (Cstruct.of_string "out")) = Ok ());
  ignore (returned (Flow.close flow));
  assert (returned (Flow.write flow (Cstruct.of_string "late")) = Error `Closed)
