#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failed=0
check_history=1

if [[ "${1:-}" == "--content-only" ]]; then
  check_history=0
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--content-only]" >&2
  exit 2
fi

report_failure() {
  echo "release audit: $1" >&2
  failed=1
}

if git ls-files \
  | rg -i '\.(png|jpe?g|gif|webp|tiff?)$' \
  | while IFS= read -r asset; do
      [[ -f "$asset" ]] && echo "$asset"
    done \
  | rg . >/dev/null; then
  report_failure "tracked raster assets require removal or an explicit audited allowlist"
fi

if rg -n --hidden \
  -g '!**/.git/**' \
  -g '!**/.build/**' \
  -g '!dist/**' \
  -g '!output/**' \
  -g '!script/release_audit.sh' \
  -e '/Users/' \
  -e '/Volumes/' \
  . >/dev/null; then
  report_failure "machine-specific absolute path found"
fi

if rg -n --hidden \
  -g '!**/.git/**' \
  -g '!**/.build/**' \
  -g '!dist/**' \
  -g '!output/**' \
  -g '!script/release_audit.sh' \
  -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
  . >/dev/null; then
  report_failure "email address found in repository content"
fi

if rg --pcre2 -n --hidden \
  -g '!**/.git/**' \
  -g '!**/.build/**' \
  -g '!dist/**' \
  -g '!output/**' \
  -g '!script/release_audit.sh' \
  -e '(?<![A-Z0-9])(?!(?:DEMO|PROJ|UTF)-)[A-Z][A-Z0-9]{1,11}-[0-9]+(?![A-Z0-9])' \
  . \
  | rg -v 'pattern: #|of: #' \
  | rg . >/dev/null; then
  report_failure "non-demo work-item identifier found"
fi

if rg -n --hidden \
  -g '!**/.git/**' \
  -g '!**/.build/**' \
  -g '!dist/**' \
  -g '!output/**' \
  -g '!script/release_audit.sh' \
  -e 'ghp_[A-Za-z0-9]+' \
  -e 'github_pat_[A-Za-z0-9_]+' \
  -e 'xox[baprs]-[A-Za-z0-9-]+' \
  -e 'sk-[A-Za-z0-9_-]{16,}' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e '-----BEGIN .*PRIVATE KEY-----' \
  . >/dev/null; then
  report_failure "credential-like value found"
fi

if [[ "$check_history" -eq 1 ]]; then
  if git log --all --format='%ae%n%ce' | rg -v '^(noreply@prnotch\.app|[0-9]+\+[^@]+@users\.noreply\.github\.com)?$' >/dev/null; then
    report_failure "public-unsafe author or committer email found in referenced history"
  fi

  if git log --all --format='%an%n%cn' | rg -v '^(PR Notch Contributors)?$' >/dev/null; then
    report_failure "personal author or committer name found in referenced history"
  fi
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "release audit: passed"
