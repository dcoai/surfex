# Surfex.ExUnitFormatter records each test's result at its exact version, as evidence
# (_build/surfex/evidence.jsonl, never committed) for `mix surfex.confirm --evidence`.
ExUnit.start(formatters: [ExUnit.CLIFormatter, Surfex.ExUnitFormatter])

# The suite never changes the project's own relation log, which CI verifies right after it
# (#341): a change fails the run, naming each file.
Surfex.Test.OwnLog.guard(Path.expand("..", __DIR__))
