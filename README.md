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

## System PATH (Administrator)

If you need to manage the Machine (system) PATH rather than your User PATH, this repo includes `fix_path_system.ps1` which performs the same cleaning, de-duplication, and PB1..PB4 rebalancing at Machine scope.

- Operates on Machine-scoped environment variables: `Path`, `PB1`, `PB2`, `PB3`, `PB4`.
- Requires an elevated PowerShell session (Run as Administrator).
- The script creates missing PB1..PB4 at Machine scope and saves a timestamped backup of the current Machine PATH and PB values to `$env:TEMP` before making changes.

Usage (in an elevated PowerShell window):

```powershell
# Run directly from the repo while elevated
.\fix_path_system.ps1

# Or as a one-off with policy bypass (when elevation is already granted)
pwsh -ExecutionPolicy Bypass -File .\fix_path_system.ps1
```

Restart shells and applications to pick up Machine-level environment changes.

## License

MIT
