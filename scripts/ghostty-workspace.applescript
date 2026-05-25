-- ghostty-workspace.applescript
-- Launch a 2x2 Ghostty grid where each pane SSHes into a named tmux session
-- on a remote host. Requires Ghostty 1.3.0+ (AppleScript support shipped then).
--
-- Defaults assume Dan's primary host. Edit `host` and `sessions` to taste, or
-- duplicate this file with different defaults for other workspaces.
--
-- Usage:
--   osascript ghostty-workspace.applescript
--
-- Or, save as an Automator/Shortcuts action and bind to a hotkey.

set host to "root@hermes-do1"
-- One session name per pane, top-left, top-right, bottom-left, bottom-right.
set sessions to {"ops", "code", "logs", "scratch"}

-- Build the remote command for one pane. `new -As` attaches to an existing
-- tmux session by that name, or creates a fresh one if it doesn't exist.
on sshCmd(host_, sess)
    return "ssh -t " & host_ & " 'tmux new -As " & sess & "' ; exit"
end sshCmd

tell application "Ghostty"
    activate

    -- Window with the first session (top-left).
    set cfg to new surface configuration
    set command of cfg to my sshCmd(host, item 1 of sessions)
    set win to new window with configuration cfg
    set paneTL to terminal 1 of selected tab of win

    -- Split right → top-right pane.
    set cfgTR to new surface configuration
    set command of cfgTR to my sshCmd(host, item 2 of sessions)
    set paneTR to split paneTL direction right with configuration cfgTR

    -- Split top-left down → bottom-left pane.
    set cfgBL to new surface configuration
    set command of cfgBL to my sshCmd(host, item 3 of sessions)
    set paneBL to split paneTL direction down with configuration cfgBL

    -- Split top-right down → bottom-right pane.
    set cfgBR to new surface configuration
    set command of cfgBR to my sshCmd(host, item 4 of sessions)
    set paneBR to split paneTR direction down with configuration cfgBR

    -- Land focus in the top-left "ops" pane by default.
    focus paneTL
end tell
