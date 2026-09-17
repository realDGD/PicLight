#!/bin/bash
# Privacy audit: scans every blob in every commit for personal identifiers.
# Read-only. Prints findings with the offending commit and file.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PATTERNS='/Users/[A-Za-z0-9._-]+|realDGD|144976081|@gmail\.com|@qq\.com|@outlook\.com|@icloud\.com|@126\.com|@163\.com|192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|\.local[^a-zA-Z]|MacBook|iMac|home/[a-z]+/|/Users/'

echo "=== personal identifiers across all commits ==="
found=0
for commit in $(git rev-list --all); do
    matches=$(git grep -I -n -E "$PATTERNS" "$commit" 2>/dev/null || true)
    if [ -n "$matches" ]; then
        echo "$matches" | sed "s|^|${commit:0:8} |"
        found=1
    fi
done
if [ "$found" -eq 0 ]; then
    echo "(none)"
fi

echo
echo "=== identifiers in commit messages ==="
git log --all --format='%H %s%n%b' | grep -n -E "$PATTERNS" || echo "(none)"

echo
echo "=== identifiers in author/committer lines ==="
git log --all --format='%an <%ae> %cn <%ce>' | sort -u

echo
echo "=== blob metadata: file types and embedded strings in tracked binaries ==="
git rev-list --all --objects | awk '{print $2}' | sort -u | grep -iE '\.(png|jpg|jpeg|gif|ico|tiff|webp|pdf)$' | while read -r path; do
    [ -z "$path" ] && continue
    blob=$(git rev-list --all --objects | grep -F " $path" | head -1 | awk '{print $1}')
    [ -z "$blob" ] && continue
    hits=$(git cat-file -p "$blob" 2>/dev/null | strings - | grep -E "$PATTERNS" | head -2 || true)
    if [ -n "$hits" ]; then
        echo "BINARY HIT $path: $hits"
        found=1
    fi
done
echo "(no BINARY HIT lines above means no personal strings inside tracked images)"
