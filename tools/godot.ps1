<#
Forwards all args to the Godot 4.6.x Mono editor executable.

Resolution order (first found wins):
1) Environment variable GODOT4_MONO_EXE
2) Standard path: C:\Projects\Godot\Godot_v{version}-stable_mono_win64\...

This script can be dot-sourced to use Resolve-GodotPath function:
  . ./tools/godot.ps1 -ResolveOnly
  $godot = Resolve-GodotPath
#>

param(
    [switch]$ResolveOnly
)

$ErrorActionPreference = "Stop"

function Resolve-GodotPath {
    $envCandidate = $env:GODOT4_MONO_EXE
    $version = if ($env:GODOT_VERSION) { $env:GODOT_VERSION } else { "4.6" }
    $standardPath = "C:\Projects\Godot\Godot_v${version}-stable_mono_win64\Godot_v${version}-stable_mono_win64.exe"

    if ($envCandidate -and (Test-Path -LiteralPath $envCandidate)) { return $envCandidate }
    if (Test-Path -LiteralPath $standardPath) { return $standardPath }
    throw "Godot executable not found. Set GODOT4_MONO_EXE or install to '$standardPath'."
}

# If -ResolveOnly, just define the function and exit (for dot-sourcing)
if ($ResolveOnly) { return }

# Otherwise, run Godot with provided args
$godot = Resolve-GodotPath
& $godot @args
exit $LASTEXITCODE
