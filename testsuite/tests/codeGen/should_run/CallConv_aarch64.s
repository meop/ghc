	.globl _someFuncF
_someFuncF:
	.globl someFuncF
someFuncF:
	fadd s16, s8, s9
	fsub s9, s8, s9
	fmov s8, s16
	fmul s16, s10, s11
	fdiv s11, s10, s11
	fmov s10, s16
	// The pushed return address is the continuation's info pointer on
	// no-TNTC targets (the RTS enters it with ENTRY_CODE, one deref).
	ldr x8, [x20]
	ldr x8, [x8]
	br x8

	.globl _someFuncD
_someFuncD:
	.globl someFuncD
someFuncD:
	fadd d16, d12, d13
	fsub d13, d12, d13
	fmov d12, d16
	fmul d16, d14, d15
	fdiv d15, d14, d15
	fmov d14, d16
	// The pushed return address is the continuation's info pointer on
	// no-TNTC targets (the RTS enters it with ENTRY_CODE, one deref).
	ldr x8, [x20]
	ldr x8, [x8]
	br x8
