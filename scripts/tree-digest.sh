#!/usr/bin/env bash
# Hash named trees by content, executable bits, directories, and link targets.
# Timestamps and checkout location are deliberately absent. Perl is a system
# utility on both supported CI images; no application/runtime dependency is added.
set -euo pipefail
[[ $# -ge 2 ]] || { echo 'usage: tree-digest.sh ROOT PATH...' >&2; exit 2; }
cd "$1"; shift
perl -MDigest::SHA -MFile::Find -e '
  use strict; use warnings;
  my @paths;
  for my $root (@ARGV) {
    -e $root || -l $root or die "Missing input: $root\n";
    find({no_chdir => 1, wanted => sub { push @paths, $File::Find::name }}, $root);
  }
  my $digest = Digest::SHA->new(256);
  for my $path (sort @paths) {
    my @stat = lstat($path); @stat or die "lstat $path: $!";
    $digest->add($path, "\0", ($stat[2] & 0111), "\0");
    if (-l _) { $digest->add("link\0", readlink($path), "\0"); }
    elsif (-d _) { $digest->add("directory\0"); }
    elsif (-f _) {
      open my $file, "<", $path or die "open $path: $!"; binmode $file;
      $digest->add("file\0", Digest::SHA->new(256)->addfile($file)->hexdigest, "\0");
      close $file or die "close $path: $!";
    } else { die "Unsupported file: $path\n"; }
  }
  print $digest->hexdigest, "\n";
' -- "$@"
