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
# Library tests: testsuite/tests/Makefile adds one --rootdir for every
# $(TOP)/../libraries/<pkg>/tests and .../tests-ghc of the installed packages, so the
# archive needs them at testsuite-tree/libraries/<pkg>/tests (and tests-ghc).
#   - Every libraries/<pkg>/tests and tests-ghc directory that is a plain directory in
#     HEAD is found automatically (base, ghc-internal, ghc-compact, ghc-heap,
#     ghc-experimental, template-haskell at the time of writing).
#   - A library that is a git submodule (gitlink) is not part of `git archive` of the
#     superproject. The ones in SUBMODULE_TESTS (array and stm: the only submodules
#     that have .T files) are archived from their own checkout. They must be
#     initialised in the worktree:  git submodule update --init libraries/array libraries/stm
#     The script stops with that command if one is missing, empty, or not at the commit
#     HEAD records for it.
#
# Output: <out-dir>/testsuite-<10-char hash>-libs.tar.gz (the suffix tells it from the older
# archives, which had no libraries/); prints its path, sha256, file count and library .T count.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <worktree> <out-dir>" >&2; exit 2; }
worktree=$1
out_dir=$2

SIBLINGS=(rts utils/haddock utils/check-exact utils/jsffi changelog.d .gitlab/hello.hs)
SUBMODULE_TESTS=(libraries/array libraries/stm)

git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git worktree: $worktree" >&2; exit 1; }
[[ -z $(git -C "$worktree" status --porcelain --untracked-files=no) ]] \
  || echo "warning: $worktree has uncommitted changes; git archive packs HEAD only" >&2

hash=$(git -C "$worktree" rev-parse HEAD)
short=$(git -C "$worktree" rev-parse --short=10 HEAD)
mkdir -p "$out_dir"
out=$(cd "$out_dir" && pwd)/testsuite-$short-libs.tar.gz

# Every submodule must be there before anything is written.
for sm in "${SUBMODULE_TESTS[@]}"; do
  want=$(git -C "$worktree" ls-tree HEAD -- "$sm" | awk '$1 == "160000" { print $3 }')
  if [[ -z $want ]]; then
    echo "error: $sm is not a submodule in $short (edit SUBMODULE_TESTS)" >&2; exit 1
  fi
  have=$(git -C "$worktree/$sm" rev-parse HEAD 2>/dev/null || true)
  # `git -C <empty submodule dir>` finds the superproject, whose HEAD is not $want.
  if [[ ! -d $worktree/$sm/tests || $have != "$want" ]]; then
    echo "error: submodule $sm is not checked out at $want in $worktree (found '${have:-nothing}')." >&2
    echo "       Run: git -C $worktree submodule update --init $sm" >&2
    exit 1
  fi
  [[ -z $(git -C "$worktree/$sm" status --porcelain --untracked-files=no) ]] \
    || echo "warning: $sm has uncommitted changes; the archive packs its HEAD only" >&2
done

paths=(testsuite)
for p in "${SIBLINGS[@]}"; do
  if [[ -n $(git -C "$worktree" ls-tree HEAD -- "$p") ]]; then
    paths+=("$p")
  else
    echo "warning: $p is not in $short; leaving it out" >&2
  fi
done

# Library test directories that are plain directories in HEAD.
libtests=()
while IFS= read -r d; do libtests+=("$d"); done \
  < <(git -C "$worktree" ls-tree -r -d --name-only HEAD libraries | grep -E '^libraries/[^/]+/tests(-ghc)?$' || true)
[[ ${#libtests[@]} -gt 0 ]] || { echo "error: no libraries/*/tests directories in $short" >&2; exit 1; }
paths+=("${libtests[@]}")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$worktree" archive --format=tar --prefix=testsuite-tree/ \
  --add-virtual-file="testsuite-tree/COMMIT:$hash" HEAD "${paths[@]}" > "$work/main.tar"

submodule_paths=()
for sm in "${SUBMODULE_TESTS[@]}"; do
  tdirs=(tests)
  [[ -n $(git -C "$worktree/$sm" ls-tree HEAD -- tests-ghc) ]] && tdirs+=(tests-ghc)
  git -C "$worktree/$sm" archive --format=tar --prefix="testsuite-tree/$sm/" HEAD "${tdirs[@]}" > "$work/sm.tar"
  tar -Af "$work/main.tar" "$work/sm.tar"
  for t in "${tdirs[@]}"; do submodule_paths+=("$sm/$t"); done
done

gzip -n -c "$work/main.tar" > "$out"

[[ $(tar -xOzf "$out" testsuite-tree/COMMIT) == "$hash" ]] || { echo "COMMIT file does not match $hash" >&2; exit 1; }
for sm in "${SUBMODULE_TESTS[@]}"; do
  tar -tzf "$out" "testsuite-tree/$sm/tests/all.T" >/dev/null 2>&1 \
    || { echo "error: $sm/tests/all.T is not in the archive" >&2; exit 1; }
done

echo "commit:  $hash"
echo "paths:   ${paths[*]} ${submodule_paths[*]}"
echo "archive: $out"
echo "sha256:  $(sha256sum "$out" | cut -d' ' -f1)"
echo "files:   $(tar -tzf "$out" | wc -l)"
echo "library .T files: $(tar -tzf "$out" | grep -cE '^testsuite-tree/libraries/[^/]+/tests(-ghc)?/.*\.T$')"
