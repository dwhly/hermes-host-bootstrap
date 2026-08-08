#!/usr/bin/env bash
# hmw-tmux — run the shared Hermes workspace implementation with tmux.

export HMW_BACKEND=tmux
exec hermes-workspace "$@"
