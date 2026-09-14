#!/usr/bin/env bash
# Kernel locks survive exec and release on failure, including SIGKILL. Never
# unlink a lock file: a waiting process must keep locking the same inode.
set -euo pipefail
[[ $# -ge 2 ]] || { echo 'usage: with-lock.sh LOCK_FILE COMMAND...' >&2; exit 2; }
mkdir -p "$(dirname "$1")"
exec perl -MFcntl=:flock -MTime::HiRes=time,sleep -e '
  my $path = shift @ARGV;
  open my $lock, ">>", $path or die "open $path: $!";
  my $deadline = time + 1200;
  until (flock($lock, LOCK_EX | LOCK_NB)) {
    time < $deadline or die "Timed out waiting for build lock: $path\n";
    sleep 0.1;
  }
  $^F = fileno($lock);
  $^F >= 0 or die "Invalid lock descriptor";
  # Clear close-on-exec on the already opened descriptor.
  fcntl($lock, Fcntl::F_SETFD(), 0) or die "fcntl: $!";
  exec @ARGV or die "exec: $!";
' -- "$@"
