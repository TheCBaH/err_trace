let check name condition = if not condition then failwith ("assertion failed: " ^ name)
let () = Portable_checks.run ~check

let () =
  Err.Config.set (Portable_checks.config Err.Action.Set.all 8);
  let imported =
    Err.Error.make_at
      ~origin:(Err.Origin.make ~source:(Err.Source.of_pos ("adapter.ml", 4, 2, 12)) ())
      (`Expected "native")
  in
  Portable_checks.check_imported ~check imported
