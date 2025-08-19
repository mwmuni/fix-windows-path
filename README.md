# fix-windows-path

A safe PowerShell helper to clean, de-duplicate, and rebalance your Windows User PATH while offloading overflow into user variables PB1..PB4.

## What it does

- Cleans and de-dupes PATH and PB1..PB4 entries (stable order preserved)
- Converts absolute paths that match existing environment variables into %VARS% to shorten PATH
- Prevents duplicates across PATH and PB1..PB4
- Inserts a "%PB1%;%PB2%;%PB3%;%PB4%" block into PATH
- Handles overflow when PATH exceeds a configurable limit (default 2000 chars)
  - Only non-variable tail entries overflow into PBs
  - Leaves variable references like %ProgramFiles% intact in PATH
- Balances pooled entries across PB1..PB4 by length while keeping order
- Idempotent: run it any time to restore order

## Usage

Run from a PowerShell prompt in this folder:

```powershell
# Option 1: current session policy allows running local scripts
./fix_path.ps1

# Option 2 (bypass policy for this invocation only)
pwsh -ExecutionPolicy Bypass -File ./fix_path.ps1
```

Notes:

- The script updates User-scoped environment variables: PATH, PB1, PB2, PB3, PB4.
- New processes pick up changes automatically; for existing apps, restart them. To update the shell, open a new PowerShell window.

## Configuration

At the top of `fix_path.ps1`:

- `$MaxLength` (default 2000): Max safe length to keep directly in PATH before spilling items into PBs. You can raise this (e.g., 4096) if you rely on many protected variable entries.
- `$PBvars`: which user variables are used as overflow buckets (PB1..PB4 by default).

## Safety

- Variable references like `%ProgramFiles%` or `%MyVar%\sub` are treated as protected and kept in PATH when possible.
- The script does not touch System-scoped variables.

## Troubleshooting

- If PATH remains long even after cleanup, check the note printed about protected entries exceeding `$MaxLength` and increase it accordingly.
- If execution policy blocks the script, use the `-ExecutionPolicy Bypass` example above for a one-off run.

## License

MIT
