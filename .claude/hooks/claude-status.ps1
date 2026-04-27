param([Parameter(Mandatory)][ValidateSet("busy","idle")][string]$Status)
try {
    Invoke-RestMethod -Uri "http://localhost:8080/claude-status" -Method Post `
        -ContentType "application/json" `
        -Body "{`"status`":`"$Status`"}" `
        -TimeoutSec 2 | Out-Null
} catch {}
