#!/bin/bash
# Editor of the mitmproxy console (MITMPROXY_EDITOR): the container has no
# editor, the file is edited with a desktop application on the Mac.
#
# mitmproxy passes a temporary file and reads it back when this script exits.
# The file is copied into /edit (./edit on the Mac), with a request
# <name>.open next to it: ./mitm attach (or open), on the Mac, opens it with
# the application in MITM_EDITOR (default: the system's default text editor).
# Enter applies the saved changes, d + Enter discards them.
# Also used by the external viewer (key v): its file is read-only and is
# opened with the default application for its type, nothing is read back.
set -u

DIR=/edit
src=$1
name=$(basename "$src")
copy=$DIR/$name

# mitmproxy makes the external viewer's file read-only
mode=edit
[ $((0$(stat -c %a "$src") & 0200)) -eq 0 ] && mode=view

cleanup() { rm -f "$copy" "$copy.open" "$copy.error" "$DIR/.$name.tmp" "$src.new"; }
trap cleanup EXIT

if ! cp "$src" "$copy"; then
  echo "Cannot write to $DIR: recreate the container (./mitm stop --rm && ./mitm start)"
  sleep 3
  exit 1
fi
[ "$mode" = view ] && chmod a-w "$copy"
# Atomic rename: the Mac never reads a half-written request
printf '%s\n' "$mode" > "$DIR/.$name.tmp"
mv "$DIR/.$name.tmp" "$copy.open"

# The Mac takes the request within ~0.5s, if ./mitm attach is running
for _ in $(seq 1 6); do
  [ -e "$copy.open" ] || break
  sleep 0.5
done
if [ -e "$copy.open" ]; then
  rm -f "$copy.open"
  echo "Not attached with ./mitm attach: open edit/$name in the project directory on the Mac"
else
  echo "Opened on the Mac: edit/$name"
fi
if [ "$mode" = view ]; then
  echo "Enter to return to mitmproxy"
else
  echo "Save the file, then Enter to apply the changes, d + Enter to discard them"
fi

# Waits for Enter, showing the error if the Mac could not open the file
shown=false
while :; do
  read -r -t 1 answer && break
  [ $? -gt 128 ] || { answer=d; break; } # EOF: discard
  if ! $shown && [ -s "$copy.error" ]; then
    echo "The Mac could not open it: $(cat "$copy.error")"
    shown=true
  fi
done

[ "$mode" = edit ] && [ "$answer" != d ] || exit 0

# A file replaced on the Mac (editors' atomic save: new file + rename) stays
# invisible through the volume for ~1s; listing the directory refreshes it.
# Through a temporary file: a failed read must not empty the original.
for _ in $(seq 1 10); do
  ls "$DIR" > /dev/null
  if cat "$copy" > "$src.new" 2> /dev/null; then
    mv "$src.new" "$src"
    exit 0
  fi
  sleep 0.5
done
echo "Cannot read edit/$name: changes not applied"
sleep 3
