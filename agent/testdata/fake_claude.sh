#!/bin/bash
# agent/testdata/fake_claude.sh — stand-in for `claude` in tests.
# Emits one canned turn per stdin line. Honours FAKE_CLAUDE_MODE:
#   normal (default) | badline | exit1 | hang
#   longline      — one stdout line far larger than the agent's scan cap,
#                    followed by a normal turn (readStdout ErrTooLong recovery)
#   deadonarrival — exits nonzero with no output at all, before ever reading
#                    stdin (a process that dies before creating the session)
#   trapsigint    — traps SIGINT, emits a clean turn_end from the trap, then
#                    exits 0 (proves SIGINT, not SIGKILL, was sent)
#   spawnchild    — forks a detached long-sleeping child and records its pid
#                    to $FAKE_CLAUDE_CHILD_PIDFILE (proves the whole process
#                    group, not just the parent, gets signalled)
# NEVER run in `hang` mode from a test — it sleeps 300s.
set -u

if [ "${FAKE_CLAUDE_MODE:-normal}" = "exit1" ]; then
  echo '{"type":"system","subtype":"init","session_id":"s"}'
  exit 1
fi

if [ "${FAKE_CLAUDE_MODE:-normal}" = "deadonarrival" ]; then
  exit 1
fi

if [ "${FAKE_CLAUDE_MODE:-normal}" = "trapsigint" ]; then
  trap 'echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"stop_reason\":\"end_turn\"}"; exit 0' INT
  echo '{"type":"system","subtype":"init","session_id":"s","model":"m"}'
  sleep 10 &
  wait $!
  exit 0
fi

if [ "${FAKE_CLAUDE_MODE:-normal}" = "spawnchild" ]; then
  echo '{"type":"system","subtype":"init","session_id":"s","model":"m"}'
  sleep 30 &
  echo $! > "${FAKE_CLAUDE_CHILD_PIDFILE:?FAKE_CLAUDE_CHILD_PIDFILE must be set for spawnchild mode}"
  wait
  exit 0
fi

while IFS= read -r _line || [ -n "$_line" ]; do
  echo '{"type":"system","subtype":"init","session_id":"s","model":"m"}'
  echo '{"type":"system","subtype":"thinking_tokens","estimated_tokens":3}'
  if [ "${FAKE_CLAUDE_MODE:-normal}" = "badline" ]; then
    echo 'this is not json'
  fi
  if [ "${FAKE_CLAUDE_MODE:-normal}" = "longline" ]; then
    head -c 1500000 /dev/zero | tr '\0' 'a'
    echo
  fi
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"hello"}]}}'
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.01,"duration_api_ms":42,"stop_reason":"end_turn","session_id":"s"}'
  if [ "${FAKE_CLAUDE_MODE:-normal}" = "hang" ]; then sleep 300; fi
done
