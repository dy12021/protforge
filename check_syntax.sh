#!/usr/bin/env bash
# Syntax-check every shell script in the tree after the rename.
cd "$(dirname "$0")" || exit 1
fail=0
count=0
while IFS= read -r f; do
    count=$((count + 1))
    if bash -n "$f" 2>/tmp/synerr; then
        printf '  ok   %s\n' "$f"
    else
        printf '  FAIL %s\n' "$f"
        sed 's/^/       /' /tmp/synerr
        fail=$((fail + 1))
    fi
done < <(find . -name '*.sh' -not -path './.git/*' | sort)
echo "checked=$count syntax_failures=$fail"
[ "$fail" -eq 0 ] || exit 1
echo "ALL SYNTAX OK"