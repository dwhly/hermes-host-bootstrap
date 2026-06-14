-- ghostty-workspace.applescript
-- Launch a 3-pane Ghostty layout where each pane SSHes into a named tmux
-- session on a remote host. Requires Ghostty 1.3.0+ (AppleScript support shipped then).
--
-- Defaults assume Dan's primary host. Edit the panes list below to retarget,
-- rename sessions, or change what each pane runs on first creation.
--
-- Usage:
--   osascript ghostty-workspace.applescript
--
-- Or, save as an Automator/Shortcuts action and bind to a hotkey.
--
-- Layout (reading top-left to bottom):
--   pane 1 (top-left)     code     →  hermes
--   pane 2 (top-right)    scratch  →  hermes
--   pane 3 (bottom, full) ops      →  plain root shell
--
-- The `logs` pane (was bottom-left, `hermes logs -f`) was removed 2026-06 —
-- Dan never used it. To bring it back, re-add a {"logs","hermes logs -f"}
-- entry to paneSpecs and a fourth split (see git history for the 2x2 form).
--
-- Note: variable names deliberately avoid AppleScript reserved words like
-- `host`, `name`, `path`, `file`, `command`. Don't rename these to shorter
-- forms without checking the AppleScript reserved-word list:
-- https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_keywords.html

-- Target host. Default is "root@h-do1" but can be overridden via the
-- first command-line argument (e.g. via `osascript … h-mini` or
-- `hermes-workspace h-mini`). Accepted forms:
--   user@host    used verbatim
--   host         user defaulted to root for h-do1, danz for h-mini,
--                otherwise root. Adjust hostUserMap below for new fleet hosts.
on hostUserMap(h)
    if h is "h-mini" then return "danz"
    return "root"
end hostUserMap

on resolveTarget(argList)
    if (count of argList) > 0 then
        set arg to item 1 of argList as string
        if arg contains "@" then return arg
        return (my hostUserMap(arg)) & "@" & arg
    end if
    return "root@h-do1"
end resolveTarget

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

on run argv
    set targetHost to my resolveTarget(argv)
    runWorkspace(targetHost)
end run

on runWorkspace(targetHost)

-- Per-pane configuration: {session-name, initial-command}.
-- Order is TL, TR, bottom. `initial-command` may be empty for "just a shell".
-- The initial-command runs in window 0 of the session ONLY on first creation
-- (via `tmux new -As name <cmd>`); reattaching does not re-run it.
--
-- code / scratch use `hermes-pane <label>` instead of bare `hermes`. That
-- wrapper (scripts/hermes-pane, symlinked to ~/.local/bin by the bootstrap)
-- makes the pane RESTART-PROOF: it stamps the session with `--source
-- pane:<label>` and resumes that pane's own most-recent session, so a
-- `hermes update` (which forces exiting hermes to pick up the new binary)
-- no longer drops the pane into a fresh empty session. On hermes exit the
-- wrapper falls to an interactive shell, so the tmux session survives. See
-- the tmux-workspace-pattern skill's continuity section for the full rationale
-- (bare `hermes --continue` is NOT safe here: it races across panes for the
-- global most-recent session and errors on first launch).
set paneSpecs to {¬
    {"code",    "hermes-pane code"},        ¬
    {"scratch", "hermes-pane scratch"},     ¬
    {"ops",     ""}                         ¬
}

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

    -- Split top-left down → bottom pane (ops, full width: splitting the
    -- top-left when there's no bottom-right keeps the bottom spanning).
    set cfg3 to new surface configuration
    set command of cfg3 to my specToCmd(targetHost, item 3 of paneSpecs)
    set paneBottom to split paneTL direction down with configuration cfg3

    -- Land focus in the top-left pane by default (code → hermes).
    focus paneTL
end tell
end runWorkspace
