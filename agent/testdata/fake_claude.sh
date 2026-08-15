#!/bin/bash
# agent/testdata/fake_claude.sh — stand-in for `claude` in tests.
# Emits one canned turn per stdin line. Honours FAKE_CLAUDE_MODE:
#   normal (default) | badline | exit1 | hang
set -u
if [ "${FAKE_CLAUDE_MODE:-normal}" = "exit1" ]; then
  echo '{"type":"system","subtype":"init","session_id":"s"}'
  exit 1
fi
while IFS= read -r _line; do
  echo '{"type":"system","subtype":"init","session_id":"s","model":"m"}'
  echo '{"type":"system","subtype":"thinking_tokens","estimated_tokens":3}'
  if [ "${FAKE_CLAUDE_MODE:-normal}" = "badline" ]; then
    echo 'this is not json'
  fi
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"hello"}]}}'
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.01,"duration_api_ms":42,"stop_reason":"end_turn","session_id":"s"}'
  if [ "${FAKE_CLAUDE_MODE:-normal}" = "hang" ]; then sleep 300; fi
done
