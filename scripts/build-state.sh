#!/usr/bin/env bash
# Shared receipt format for prepared source and compact native build outputs.
# Callers hold the corresponding lock through validation, replacement, and use.
root=${root:?caller must set the repository root}

tree_digest() { "$root/scripts/tree-digest.sh" "$@"; }
receipt_valid() {
  local directory=$1 receipt=$2 inputs=$3 actual
  [[ -d $directory && -f $receipt ]] || return 1
  jq -e --arg inputs "$inputs" '.schema == 1 and .inputs == $inputs' "$receipt" > /dev/null || return 1
  actual=$(tree_digest "$directory" .) || return 1
  [[ $(jq -er .outputs "$receipt") == "$actual" ]]
}
write_receipt() {
  local directory=$1 receipt=$2 inputs=$3 actual
  actual=$(tree_digest "$directory" .) || return 1
  jq -n --arg inputs "$inputs" --arg outputs "$actual" \
    '{schema: 1, inputs: $inputs, outputs: $outputs}' > "$receipt.tmp" || return 1
  mv "$receipt.tmp" "$receipt"
}
replace_directory() {
  local staged=$1 destination=$2
  # Every reader holds the same lock. A crash between renames leaves no valid
  # receipt; the next invocation rebuilds. No partially copied tree is published.
  rm -rf "$destination.previous"
  if [[ -e $destination ]]; then mv "$destination" "$destination.previous"; fi
  mv "$staged" "$destination"
  rm -rf "$destination.previous"
}
