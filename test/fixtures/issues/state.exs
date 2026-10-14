# A stand-in for a project's tracker command (§13.7): answers by issue number, so the
# tests of `issues:` and `mix surfex.status --issues` need no network. Its arguments are
# what the declared command substitutes: {n}, {ref} and {project}.
[n, ref, project] = System.argv()

case n do
  "1" -> IO.puts("opened")
  "2" -> IO.puts(~s({"state":"closed"}))
  "3" -> IO.puts("garbage")
  "4" -> IO.puts(if ref == "acme/tools#4" and project == "acme/tools", do: "OPEN", else: "?")
  "5" -> IO.puts(if ref == "#5" and project == "fallback/project", do: "closed", else: "?")
  "6" -> IO.puts(~s({"status":"closed"}))
  "9" -> IO.puts("the tracker is down") && System.halt(2)
  _ -> IO.puts("unknown")
end
