#!/usr/bin/env bash
# hmw-herdr — run the shared Hermes workspace implementation with Herdr.

export HMW_BACKEND=herdr
exec hermes-workspace "$@"
