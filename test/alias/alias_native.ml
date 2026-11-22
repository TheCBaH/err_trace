let check name condition = if not condition then failwith ("assertion failed: " ^ name)
let () = Alias_checks.run ~check
