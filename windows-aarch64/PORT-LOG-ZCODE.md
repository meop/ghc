# Windows ARM64 port — work log (ZCode/GLM session, 2026-11-15..)

Review companion to `TODO.md` (which holds the standing plan, milestones and
environment). This file records what this session did, the evidence behind
each conclusion, and what is still open, so another agent can review without
re-deriving it. New entries are appended at the end. Nothing here has gone
upstream: the only open upstream PRs are network #651 and hsc2hs #109 (plus
issue #108), opened earlier and awaiting review.

## Starting state (2026-11-15 ~21:00 UTC)

- `aarch64-coff-linker` branch (405a406474, 4 linker cherry-picks on master
  13408a2b59) had a validated bindist: release ghc-10.1.20261114-405a406474,
  15/15 host checks, GHCi/TH/SEH verified, test-ghc CI green.
- The procpoint fix (branch `procpoint-entry-label-non-tntc`, first attempt
  22c162f0aa) was written but NOT yet validated; it fixed the CallConv test
  crash (info label executed without TNTC) by rewriting procpoint block
  literals to entry labels.
- test-packages CI was failing on patch/version drift.
- Full testsuite runs: two runs (2026-11-14 and -15) with bit-identical
  failure sets: 205 problem tests (153 unexpected + 52 framework).

## 1. The stale-bindist false start

The first procpoint validation ran a bindist packaged from a `_build` state
built BEFORE the fix merge; CallConv still crashed as expected. Lesson
recorded: package only after confirming the artifact timestamp postdates the
change. Two subsequent transfers were also tested against stale copies in
the test directory (hash mismatch caught it); the transfer+verify+test
sequence is now: package → `hosts.nu put` to remote home → copy into the
test dir → verify sha256 → extract/test.

## 2. Every post-merge ghc.exe died at startup — the long hunt

After the merge, EVERY stone-built ghc.exe failed: silent instant exit,
code 0xC000009A (STATUS_INSUFFICIENT_RESOURCES). CI-built ghc.exe from the
same branch worked. Evidence gathered, in order:

1. Incremental relink was not the cause: a full `CLEAN=1` rebuild
   reproduced it (hash-verified transfer).
2. The procpoint fix was not the cause: reverting it and rebuilding also
   produced a dead exe. (This test was later found to be contaminated —
   see §4 — but a clean with-fix rebuild reproduced the death
   independently.)
3. Not Defender/hash reputation: a one-byte-appended copy of the good exe
   (new hash) loads; the bad exes fail from any path/name.
4. Not resource exhaustion: the system commits 3 GB fine; free commit
   ~2.4 GB.
5. PE structure identical: headers, imports, .reloc (2.3M entries, all
   valid), stack reserve — byte-level section diff good-vs-bad showed only
   compiler-code differences and benign link-order pointer swaps.
6. All 79,147 text functions hash-identical between the working (CI) build
   and the dead (revert) build. Code identical; the death is runtime.
7. WinDbg (installed with user approval) caught it: first-chance c00000aa,
   `pc = x17 = 0xd3401e3139401ed1` — bytes of ARM64 instructions used as an
   address. The failing sequence is GHC closure entry:
   `ldr x17,[x20]; ldr x17,[x17]; br x17` — x20 was a heap closure whose
   info field pointed into .text (`ReadP_zdfFunctorReadP2_entry+0x50`), so
   the second load read instruction bytes and `br` went wild.
8. Root cause: without TNTC, a heap-allocated continuation closure's info
   word must be the INFO label (data; the RTS enters via
   `entryCode`/`%ENTRY_CODE`, i.e. loads the entry through the info table),
   but the first procpoint fix rewrote it to the ENTRY label (code).

Key false lead to record: two `CmmBlock` consumption styles both exist for
stack pushes too, and distinguishing them took the rest of §3.

## 3. What the pre-fix compiler actually got wrong (and right)

Ground truth assembled from the RTS and generated code:

- RTS resume of interrupted frames: `jump %ENTRY_CODE(Sp(0)) []` — without
  TNTC `entryCode` is `load [x]` — one load, direct jump → the pushed value
  must be ENTRY code.
- `stg_ap_pp_fast` and friends do two loads — but those are closure ENTERS
  (R = closure → info → entry), not return-address reads.
- Generated normal-call returns: `ldr x17,[Sp-off]; br x17` — direct.
- The CallConv test's prim callee does `ldr x8,[Sp]; blr x8` — direct.
⇒ Every stack-pushed return address is executed directly: ENTRY label.
⇒ Only heap-closure info words are data: INFO label.

The pre-fix (upstream) rewrite mapped ALL block literals to the info label:
correct for heap stores, wrong for everything executed — which explains not
only CallConv but likely a chunk of the 205-failure baseline (safe foreign
call resumes would execute data). The first fix mapped everything to the
entry label: fixes the executed uses, kills the compiler on its own closure
info words. Both wrong; position is the discriminator.

## 4. The revert experiment was invalid (stale objects)

The revert build did not recompile `ReadP.o` (its fingerprint does not
depend on `GHC.Cmm.ProcPoint`), so the "reverted" bindist still carried the
first-fix-compiled ReadP object and died at the same closure. Incremental
rebuilds of the compiler cannot undo codegen changes for downstream
objects; when changing compiler codegen, stage2 objects must be wiped. (The
clean with-fix rebuild dying independently still proves §2's root cause,
but the revert "proof" was coincidental.)

## 5. The position-aware fix (current, branch `procpoint-entry-label-non-tntc`)

Commit bdc28c09d9 (amended twice for API drift: `CmmLoad` has 3 fields;
`mapExp` is node-level so a recursive expr mapper was needed):

- middle nodes: `CmmStore` whose address mentions `Hp` → info label (data);
  everything else in middles → entry label.
- last nodes (call targets/args, jumps) → entry label.
- literals not in `procLabels` are left alone (NCG prints the block's entry
  label — upstream behavior for non-callPP references).

Remaining risk, stated plainly: `mentionsHp` is syntactic. A heap store
whose address was routed through a local register would be misclassified —
but the sink pass runs BEFORE procpoint splitting, so stored values are
still in their original form. The testsuite is the arbiter.

## 6. test-packages CI — three fixes, one pivot

- Run 43694418845 (fail): "version-agnostic" patch matching pulled the
  Cabal 3.12 patch (hadolint's) into the cabal build; its apply failure
  aborted the loop before the network patch → network 3.2.13 built
  unpatched.
- Fix 39cb2d1 (run 43765278584): per-patch version probe against the
  solver; only applicable patches are unpacked/patched/pinned. Worked —
  native ARM64 cabal.exe built in CI for the first time with this GHC.
- Run 43770202524 (fail): GHC master made noncanonical instance
  definitions HARD errors; `-Wno-noncanonical-*` is deprecated and ignored
  (verified directly with the stage1 compiler). Flags removed.
- Fix c946fb8 (run 43779268303): stored patches that delete the dead
  `mappend` from strict-0.5.1 and `return` from blaze-markup-0.8.3.0 — the
  two packages ShellCheck/hadolint actually resolve to.

## 7. Testsuite baseline corrections (fork wip branch, 655522ee67)

- The two full runs are bit-identical: 205 problem tests. The "46" recorded
  earlier was a targeted-subset number and has been corrected in TODO.md.
- The ~55-test plugins cluster is environmental: the driver hands msys make
  a Windows-style `TOP` and make eats the backslashes
  (`C:Usersmarshall.../mk/boilerplate.mk` not found). Not compiler bugs.
- Awaiting: full rerun with the position-aware fix to measure the real
  delta — expected to fix CallConv plus an unknown number of
  executed-data failures hidden in the long tail.

## 8. x86_64-windows ↔ aarch64-windows gap matrix (living)

| # | Gap (x64 has, ARM64 lacks) | Status |
|---|---|---|
| 1 | TNTC: info==entry address | position-aware fix in validation (§5) |
| 2 | RTS linker COFF relocations | done, validated earlier (405a406474) |
| 3 | C calling convention (AAPCS64 vs x64; arg extension) | #27684, milestone 4, not started |
| 4 | x18 register free on x64, platform-reserved on Windows ARM64 | -ffixed-x18, milestone 4, not started |
| 5 | Large address space / heap reservation | not yet compared, milestone 4 |
| 6 | Split sections | milestone 4, not started |
| 7 | SIMD/constant test expectations written for x86 output | classify vs x64 baseline (§7) |
| 8 | hsc2hs --via-asm CodeView | PR #109 open |
| 9 | Plugin loading (RTS linker + DLL semantics) | partially environmental (§7); needs x64 baseline too |

Planned next, per the review discussion: fetch upstream CI's
x86_64-windows testsuite results and diff our failure set against that
baseline, so the remaining work is ordered by measured gap instead of by
whichever mystery surfaced last.

## Artifacts

- Branch: meop/ghc `procpoint-entry-label-non-tntc` (bdc28c09d9, not yet
  pushed — push after local validation), merged into the
  `aarch64-coff-linker` build tree.
- Crash evidence: %LOCALAPPDATA%\ghc-dumps\hung2.dmp (minidump of the wild
  jump); cdb session logs in the session transcript.
- CI: runs 43765278584 (cabal OK), 43770202524 (hard errors found),
  43779268303 (patches).
- Stone logs: /tmp/ghc-fullclean-build.log (clean with first fix),
  /tmp/ghc-fix2-build.log (position-aware fix).

## Update 2026-11-16 ~01:30 UTC

Where things actually stand (in answer to "how far did you get, is the doc
current?"):

- Position-aware procpoint fix (bdc28c09d9): code complete and committed on
  the branch, stage2 clean rebuild on stone still running (mid-compiler,
  ~6000/~7000 modules). NOT yet validated on acrylic — the doc above said
  "in validation" and that is still literally true.
- test-packages: run 43779268303 failed AFTER this doc was written; the
  failure is the same hard-error class one package further: semialign-1.4
  (Data/Zip.hs, Zippy Monoid mappend). The strict and blaze-markup patches
  WORKED (ShellCheck got past Tuple.hs; hadolint got past Internal.hs).
  Fixed febd8e9 (same delete-the-dead-definition patch), run 43788101648
  dispatched. Lesson: I added packages one CI run at a time instead of
  enumerating every package in both plans up front for noncanonical
  definitions — should have swept all candidate packages in one pass.
- Work log itself: created 4e8e0bdb68; this section brings it current.

Next steps unchanged: validate the fix bindist on acrylic when the build
lands (15 checks + CallConv + SEH + GHCi), then push branch + release + CI,
then the x86_64-windows baseline diff, then the full local testsuite rerun.


## Update 2 — 2026-11-16, the procpoint saga resolved (correctly this time)

Sections 2–5 above documented a hunt whose conclusion was wrong. The final
story, with the full evidence chain:

### The loop

Every stone-built ghc.exe carrying ANY procpoint change died instantly at
startup (silent exit, 0xC000009A):

1. First fix (all `CmmBlock` literals → entry labels): dead. Minidump + cdb
   showed the wild jump: closure info word = entry-code bytes, entered by
   `ldr x17,[x20]; ldr x17,[x17]; br x17`.
2. Position-aware fix (heap stores → info, stack pushes/calls → entry):
   also dead, same signature, even after a full stage2 wipe (a rebuild with
   stale objects first produced a false confirmation of the same diagnosis).
3. The revert "experiment" (§4) was invalid — stale `ReadP.o`.

### The resolution — upstream was right all along

Diffing relocations in `ReadP.o` (correct object, position-aware compiler):

- `stur x17, [x21, #-0x18]` (x21 = Hp — heap info words): relocates to
  **.data** (info tables) — my fix's classification, "correct" by my model.
- `stur x17, [x20, #-0x18]` (x20 = Sp — pushed return addresses): relocates
  to **.text** (entry code) — my fix's classification.

But the consumer of a pushed return address is the **RTS/Cmm return
convention**: `jump %ENTRY_CODE(Sp(0))`, where without TNTC `entryCode` is
one dereference — `ldr x17,[x20]; ldr x17,[x17]; br x17`. The pushed value
must be an **info label**; the return path dereferences it. My "entry"
pushes made every continuation return execute instruction bytes. That exact
sequence was the crash.

So the upstream pre-fix `replacePPIds` (rewrite ALL procpoint references to
the info label) is correct for this target: heap closures need info words
(data), and stack-pushed return addresses are consumed info-style by every
Cmm/RTS return path.

### The actual gap: the CallConv test's hand-written asm

The one consumer that jumps to a pushed value directly — no deref — is the
hand-written callee in `testsuite/tests/codeGen/should_run/
CallConv_aarch64.s`: `ldr x8, [x20]; blr x8`. That assumes TNTC, where
info == entry. On aarch64-unknown-mingw32 it executed the info table = the
original "access violation executing data". This is a TEST bug, not a
compiler bug: `foreign import prim` continuations follow the standard
pushed-info-pointer convention.

Fix (fork wip branch, 26517e2e63): deref then jump — `ldr x8, [x20];
ldr x8, [x8]; br x8` in both someFuncF and someFuncD. Verified on acrylic
against the STOCK release bindist (no compiler change): CallConv compiles,
runs, exact expected output (4.0/-2.0/8.0/2.0 twice), exit 0.

### Consequences

- Branch `procpoint-entry-label-non-tntc` deleted (reset to master);
  the build tree reset to `aarch64-coff-linker` 405a406474. No compiler
  change is needed for this cluster; nothing to push upstream from it.
- The baseline's CallConv failure is removed by the testsuite fix, synced
  into the local runner tree. A full rerun with the release bindist is
  started; the remaining failure set needs reclassification against the
  x86_64-windows baseline (still planned).
- Compiler-change lesson (general): a Cmm-level codegen change does not
  rebuild library objects incrementally (fingerprints don't track the
  compiler), and a revert experiment MUST wipe the objects compiled by the
  changed compiler. Both were violated once each; both cost hours.

### Convention facts established (for milestone 4 / #27684 work)

- Non-TNTC: `ENTRY_CODE(x)` = `[x]` (one deref); pushed return addresses
  are info pointers; heap closure info words are info labels.
- Hand-written asm receiving a pushed return address (prim callees) must
  deref once before jumping on this target.
- `stg_ap_pp_fast`-style double loads are closure ENTERS (R → info →
  entry), not return-address reads — they were a false lead.

## Update 3 — 2026-11-16, the x86_64-windows baseline

Fetched from upstream CI (gitlab ghc/ghc, master pipeline 133474, commit
b70226249739, job `x86_64-windows-validate-test`, junit.xml saved here as
`x86_64-windows-master-junit.xml`): **12,008 test cases, 0 failures** on
x86_64-windows master.

Consequence: every entry in our 205-test problem set is a genuine
aarch64-windows delta (or a local runner environment issue), not upstream
Windows noise. Classification work remaining: subtract the ~55 plugins
pre_cmd environmental cluster, then group the rest by mechanism
(SIMD/constant expectations, interpreter/TH, framework) to order milestone
4. The testsuite rerun with the release bindist + fixed CallConv asm is
running; its delta vs 205 is the next data point.

## Update 4 — 2026-11-16, test-packages fully green

Run 43788101648 (release ghc-10.1.20261114-405a406474 on the
windows-11-arm runner): native ARM64 cabal.exe builds and self-hosts,
ShellCheck 0.11.0 builds + test suite passes, hadolint 2.15.1 builds +
742/742 tests pass. The per-patch version probe selected the right subset
per build (network only for cabal-install; semialign+strict for
ShellCheck; blaze-markup+Cabal-3.12+semialign+strict for hadolint),
confirming 39cb2d1 + c946fb8 + febd8e9 work as designed.

The noncanonical-instance patches (strict, blaze-markup, semialign) are
workarounds for GHC master making noncanonical definitions hard errors;
the real fix belongs upstream in those packages. When upstream releases
patched versions, the stored patches can be dropped.
