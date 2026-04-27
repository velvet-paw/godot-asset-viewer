#!/usr/bin/env bash
# Forwards all args to the Godot 4.6.x Mono editor executable.
#
# Resolution order (first found wins):
# 1) Environment variable GODOT4_MONO_EXE
# 2) godot on PATH
# 3) godot4 on PATH
# 4) ~/.local/bin/godot
# 5) Flatpak: flatpak run org.godotengine.GodotSharp
#
# Can be sourced to use resolve_godot_path function:
#   source ./tools/godot.sh --resolve-only
#   GODOT=$(resolve_godot_path)

set -euo pipefail

resolve_godot_path() {
    if [[ -n "${GODOT4_MONO_EXE:-}" ]] && [[ -x "$GODOT4_MONO_EXE" ]]; then
        echo "$GODOT4_MONO_EXE"
        return
    fi

    if command -v godot &>/dev/null; then
        command -v godot
        return
    fi

    if command -v godot4 &>/dev/null; then
        command -v godot4
        return
    fi

    local local_bin="$HOME/.local/bin/godot"
    if [[ -x "$local_bin" ]]; then
        echo "$local_bin"
        return
    fi

    if command -v flatpak &>/dev/null && flatpak info org.godotengine.GodotSharp &>/dev/null; then
        echo "flatpak run org.godotengine.GodotSharp"
        return
    fi

    echo "Error: Godot executable not found." >&2
    echo "Set GODOT4_MONO_EXE or install Godot to one of:" >&2
    echo "  - godot / godot4 on PATH" >&2
    echo "  - ~/.local/bin/godot" >&2
    echo "  - Flatpak: org.godotengine.GodotSharp" >&2
    return 1
}

# If --resolve-only, just define the function and exit (for sourcing)
if [[ "${1:-}" == "--resolve-only" ]]; then
    return 0 2>/dev/null || exit 0
fi

GODOT=$(resolve_godot_path)
# Handle flatpak case (multi-word command) by using eval
$GODOT "$@"
exit $?
