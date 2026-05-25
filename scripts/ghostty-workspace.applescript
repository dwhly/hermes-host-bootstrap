-- ghostty-workspace.applescript
-- Launch a 2x2 Ghostty grid where each pane SSHes into a named tmux session
-- on a remote host. Requires Ghostty 1.3.0+ (AppleScript support shipped then).
--
-- Defaults assume Dan's primary host. Edit `targetHost` and `sessionNames`
-- to taste, or duplicate this file with different defaults for other workspaces.
--
-- Usage:
--   osascript ghostty-workspace.applescript
--
-- Or, save as an Automator/Shortcuts action and bind to a hotkey.
--
-- Note: variable names deliberately avoid AppleScript reserved words like
-- `host`, `name`, `path`, `file`, `command`. Don't rename these to shorter
-- forms without checking https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_keywords.html

set targetHost to "root@hermes-do1"
-- One session name per pane, top-left, top-right, bottom-left, bottom-right.
set sessionNames to {"ops", "code", "logs", "scratch"}

-- Build the remote command for one pane. `new -As` attaches to an existing
-- tmux session by that name, or creates a fresh one if it doesn't exist.
-- We use `ghostty +ssh` (a drop-in ssh wrapper Ghostty ships) instead of
-- raw ssh because it auto-installs Ghostty's terminfo entry on the remote
-- the first time you connect, then caches the install. Without this, tmux
-- on the remote dies with "missing or unsuitable terminal: xterm-ghostty"
-- because most distros don't ship the xterm-ghostty terminfo entry yet.
-- See https://ghostty.org/docs/features/ssh
on sshCmd(h, s)
    return "ghostty +ssh " & h & " -t 'tmux new -As " & s & "' ; exit"
end sshCmd

tell application "Ghostty"
    activate

    -- Window with the first session (top-left).
    set cfg1 to new surface configuration
    set command of cfg1 to my sshCmd(targetHost, item 1 of sessionNames)
    set win to new window with configuration cfg1
    set paneTL to terminal 1 of selected tab of win

    -- Split right → top-right pane.
    set cfg2 to new surface configuration
    set command of cfg2 to my sshCmd(targetHost, item 2 of sessionNames)
    set paneTR to split paneTL direction right with configuration cfg2

    -- Split top-left down → bottom-left pane.
    set cfg3 to new surface configuration
    set command of cfg3 to my sshCmd(targetHost, item 3 of sessionNames)
    set paneBL to split paneTL direction down with configuration cfg3

    -- Split top-right down → bottom-right pane.
    set cfg4 to new surface configuration
    set command of cfg4 to my sshCmd(targetHost, item 4 of sessionNames)
    set paneBR to split paneTR direction down with configuration cfg4

    -- Land focus in the top-left "ops" pane by default.
    focus paneTL
end tell
