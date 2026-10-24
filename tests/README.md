# Tests

`test-paths.ps1` checks path detection and rewriting (plain, JSON-escaped, forward-slash,
UTF-16 registry files, binary files). It runs anywhere PowerShell 7 runs:

```powershell
pwsh -NoProfile -File tests/test-paths.ps1
```

Real-world testing: run **Preview only** on a new PC. It builds the full plan and the HTML
report without changing anything.
