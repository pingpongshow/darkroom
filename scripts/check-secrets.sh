#!/usr/bin/env bash
# Blocks commits that contain personal data or secrets.
#
# Checks staged (or given) files for:
#   - email addresses (GitHub no-reply and example domains are allowed)
#   - private/LAN IPv4 addresses (loopback is allowed)
#   - private keys, API keys / tokens
#   - any term listed in the local, untracked denylist (.git/info/personal-denylist),
#     e.g. real names, hostnames, server addresses
#
# Usage: scripts/check-secrets.sh            # checks staged files (pre-commit)
#        scripts/check-secrets.sh <files...>  # checks the given files
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
denylist="$root/.git/info/personal-denylist"

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(git diff --cached --name-only --diff-filter=ACMR -z)
fi

[[ ${#files[@]} -eq 0 ]] && exit 0

status=0
report() { echo "✖ $1: $2" >&2; status=1; }

for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  # Unmodified third-party code (verified against upstream checksums, see Vendor/*/VENDORED.txt).
  [[ "$f" == Vendor/* ]] && continue
  # Skip binary files
  if ! grep -Iq . "$f" 2>/dev/null; then continue; fi
  content="$(git show ":$f" 2>/dev/null || cat "$f")"

  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    case "$m" in
      *@users.noreply.github.com|*@example.com|*@example.org|*@example.net|*.test|*.example|*.invalid|*.localhost|*@test.local) ;;
      *) report "$f" "email address: $m" ;;
    esac
  done < <(grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' <<<"$content" | sort -u || true)

  # Files can opt out of the generic private-IP check with the marker "check-secrets: allow-example-ips"
  # (e.g. subnet-logic tests). The personal denylist below still applies to them.
  if ! grep -q "check-secrets: allow-example-ips" <<<"$content" && grep -Eq '(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9.]|$)' <<<"$content"; then
    report "$f" "private/LAN IP address"
  fi

  if grep -Eq -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}' <<<"$content"; then
    report "$f" "private key or access token"
  fi
  if grep -Eiq '(api[_-]?key|access[_-]?token|secret|password)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9+/_-]{20,}["'"'"']' <<<"$content"; then
    report "$f" "hard-coded credential"
  fi

  if [[ -f "$denylist" ]]; then
    while IFS= read -r term; do
      [[ -z "$term" || "$term" == \#* ]] && continue
      if grep -Fiq -- "$term" <<<"$content"; then
        report "$f" "personal term from local denylist"
      fi
    done < "$denylist"
  fi
done

if [[ $status -ne 0 ]]; then
  echo "Commit blocked: remove personal data/secrets (see above). Local values belong in Local.xcconfig or the Keychain." >&2
fi
exit $status
