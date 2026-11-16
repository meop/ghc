#!/usr/bin/env bash
# Build a testsuite archive from a GHC worktree for windows-aarch64/testsuite-on-host.ps1.
#
#   make-test-archive.sh <worktree> <out-dir>
#
# The archive is `git archive` of the worktree's HEAD, with the prefix
# testsuite-tree/, holding testsuite/ plus the sibling source directories that
# some tests reach through {top}/.. or $(TOP)/.. (the testsuite is run from
# testsuite-tree/testsuite, so ".." is testsuite-tree). It also holds the
# virtual file testsuite-tree/COMMIT with the full HEAD hash, which the runner
# checks against -ExpectTree.
#
# Sibling paths (found by grepping testsuite/ for {top}/.., $(TOP)/.. and ../../..):
#   rts                 TimeoutQueue, ClosureTable, testwsdeque, rts-check-symbols,
#                       subsections_via_symbols
#   utils/haddock       haddockHtmlTest, haddockLatexTest, haddockHoogleTest, haddockHypsrcTest
#   changelog.d         changelog-d
#   utils/check-exact   T23103 (extra_files)
#   utils/jsffi, .gitlab/hello.hs   ghc-api-browser (extra_files)
#
# Output: <out-dir>/testsuite-<10-char hash>.tar.gz; prints its path, sha256 and file count.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <worktree> <out-dir>" >&2; exit 2; }
worktree=$1
out_dir=$2

SIBLINGS=(rts utils/haddock utils/check-exact utils/jsffi changelog.d .gitlab/hello.hs)

git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git worktree: $worktree" >&2; exit 1; }
[[ -z $(git -C "$worktree" status --porcelain --untracked-files=no) ]] \
  || echo "warning: $worktree has uncommitted changes; git archive packs HEAD only" >&2

hash=$(git -C "$worktree" rev-parse HEAD)
short=$(git -C "$worktree" rev-parse --short=10 HEAD)
mkdir -p "$out_dir"
out=$(cd "$out_dir" && pwd)/testsuite-$short.tar.gz

paths=(testsuite)
for p in "${SIBLINGS[@]}"; do
  if [[ -n $(git -C "$worktree" ls-tree HEAD -- "$p") ]]; then
    paths+=("$p")
  else
    echo "warning: $p is not in $short; leaving it out" >&2
  fi
done

git -C "$worktree" archive --format=tar.gz --prefix=testsuite-tree/ \
  --add-virtual-file="testsuite-tree/COMMIT:$hash" HEAD "${paths[@]}" > "$out"

[[ $(tar -xOzf "$out" testsuite-tree/COMMIT) == "$hash" ]] || { echo "COMMIT file does not match $hash" >&2; exit 1; }

echo "commit:  $hash"
echo "paths:   ${paths[*]}"
echo "archive: $out"
echo "sha256:  $(sha256sum "$out" | cut -d' ' -f1)"
echo "files:   $(tar -tzf "$out" | wc -l)"
