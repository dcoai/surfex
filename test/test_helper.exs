# Surfex.ExUnitFormatter records each test's result at its exact version, as evidence
# (_build/surfex/evidence.jsonl, never committed) for `mix surfex.confirm --evidence`.
ExUnit.start(formatters: [ExUnit.CLIFormatter, Surfex.ExUnitFormatter])
