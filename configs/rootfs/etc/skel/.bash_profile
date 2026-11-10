# shellcheck shell=bash
# Logging in on tty1 starts the Emunix session. When the session ends, this leaves a shell on the
# VT with the journal hint instead of a black screen. EMUNIX_SESSION stops that shell from
# re-entering the session in a loop.
if [ "$(tty)" = /dev/tty1 ] && [ -z "${EMUNIX_SESSION:-}" ]; then
  export EMUNIX_SESSION=1
  systemctl --user start --wait emunix-session
  status=$?
  if [ "$status" -ne 0 ]; then
    printf '\nThe Emunix session exited with status %s.\n' "$status"
    printf 'See: journalctl --user -b -u emunix-session\n\n'
  fi
  exec bash -l
fi
