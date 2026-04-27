extends SceneTree

# Headless-safe input setup. Adds actions and default key bindings, then saves to project settings.
# To add new actions: add entries to the `actions` dictionary below and re-run this script.
# Keys are KEY_* constants from @GlobalScope. Multiple keys = alternatives for the same action.

func _initialize() -> void:
    var actions := {
        "move_forward": [KEY_W, KEY_UP],
        "move_backward": [KEY_S, KEY_DOWN],
        "move_left": [KEY_A, KEY_LEFT],
        "move_right": [KEY_D, KEY_RIGHT],
        "jump": [KEY_SPACE],
        "crouch": [KEY_CTRL],
        "sprint": [KEY_SHIFT],
        "swim_up": [KEY_E],
        "swim_down": [KEY_Q]
    }

    for action in actions.keys():
        if not InputMap.has_action(action):
            InputMap.add_action(action)
            print("[InputSetupCLI] Added action: ", action)

        # Add default events if none present
        var existing := InputMap.action_get_events(action)
        if existing.is_empty():
            for key in actions[action]:
                var ev := InputEventKey.new()
                ev.physical_keycode = key
                InputMap.action_add_event(action, ev)
            print("[InputSetupCLI] Bound keys for ", action, ": ", actions[action])

        # Persist to project settings
        var evs := InputMap.action_get_events(action)
        var entry := {
            "deadzone": 0.5,
            "events": evs
        }
        ProjectSettings.set_setting("input/%s" % action, entry)

    var save_ok := ProjectSettings.save()
    if save_ok != OK:
        push_error("[InputSetupCLI] Failed to save ProjectSettings: %s" % save_ok)
    else:
        print("[InputSetupCLI] ProjectSettings saved.")
    quit()


