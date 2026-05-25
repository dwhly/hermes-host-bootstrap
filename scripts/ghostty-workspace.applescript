-- ghostty-workspace.applescript
-- Launch a 2x2 Ghostty grid where each pane SSHes into a named tmux session
-- on a remote host. Requires Ghostty 1.3.0+ (AppleScript support shipped then).
--
-- Defaults assume Dan's primary host. Edit the panes list below to retarget,
-- rename sessions, or change what each pane runs on first creation.
--
-- Usage:
--   osascript ghostty-workspace.applescript
--
-- Or, save as an Automator/Shortcuts action and bind to a hotkey.
--
-- Layout (reading top-left to bottom-right):
--   pane 1 (top-left)     code     →  hermes
--   pane 2 (top-right)    scratch  →  hermes
--   pane 3 (bottom-left)  logs     →  hermes logs gateway -f
--   pane 4 (bottom-right) ops      →  plain root shell
--
-- Note: variable names deliberately avoid AppleScript reserved words like
-- `host`, `name`, `path`, `file`, `command`. Don't rename these to shorter
-- forms without checking the AppleScript reserved-word list:
-- https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_keywords.html

set targetHost to "root@hermes-do1"

-- Per-pane configuration: {session-name, initial-command}.
-- Order is TL, TR, BL, BR. `initial-command` may be empty for "just a shell".
-- The initial-command runs in window 0 of the session ONLY on first creation
-- (via `tmux new -As name <cmd>`); reattaching does not re-run it.
set paneSpecs to {¬
    {"code",    "hermes"},                  ¬
    {"scratch", "hermes"},                  ¬
    {"logs",    "hermes logs gateway -f"},  ¬
    {"ops",     ""}                         ¬
}

-- Build the ssh command for one pane.
--   ssh -t <host> "tmux new -As <session> [<initial-cmd>]"
-- `tmux new -As name` attaches an existing session or creates a fresh one.
-- When creating, an optional trailing command becomes the session's main
-- process; when it exits, the session ends.
--
-- We use plain `ssh -t` rather than `ghostty +ssh`. `+ssh` is meant to be
-- the right answer here — it auto-installs xterm-ghostty terminfo on the
-- remote — but in Ghostty 1.3.1 it has bugs that produce 'invalid action'
-- errors and SIGTRAPs. The reliable path is `term = xterm-256color` in
-- ~/.config/ghostty/config. See https://ghostty.org/docs/help/terminfo
on sshCmd(h, s, initial)
    if initial is "" then
        return "ssh -t " & h & " 'tmux new -As " & s & "' ; exit"
    else
        return "ssh -t " & h & " \"tmux new -As " & s & " '" & initial & "'\" ; exit"
    end if
end sshCmd

on specToCmd(h, spec)
    return my sshCmd(h, item 1 of spec, item 2 of spec)
end specToCmd

tell application "Ghostty"
    activate

    -- Window with the first pane (top-left).
    set cfg1 to new surface configuration
    set command of cfg1 to my specToCmd(targetHost, item 1 of paneSpecs)
    set win to new window with configuration cfg1
    set paneTL to terminal 1 of selected tab of win

    -- Split right → top-right pane.
    set cfg2 to new surface configuration
    set command of cfg2 to my specToCmd(targetHost, item 2 of paneSpecs)
    set paneTR to split paneTL direction right with configuration cfg2

    -- Split top-left down → bottom-left pane.
    set cfg3 to new surface configuration
    set command of cfg3 to my specToCmd(targetHost, item 3 of paneSpecs)
    set paneBL to split paneTL direction down with configuration cfg3

    -- Split top-right down → bottom-right pane.
    set cfg4 to new surface configuration
    set command of cfg4 to my specToCmd(targetHost, item 4 of paneSpecs)
    set paneBR to split paneTR direction down with configuration cfg4

    -- Land focus in the top-left pane by default (code → hermes).
    focus paneTL
end tell
