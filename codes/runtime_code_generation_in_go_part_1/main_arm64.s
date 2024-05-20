#include "funcdata.h"
#include "textflag.h"

TEXT ·exec(SB), NOSPLIT|NOFRAME, $0-8
    // Load the entry point of the executable into R27.
	MOVD entrypoint+0(FP), R27
	// Jump to the entry point of the executable stored in R27.
	JMP  (R27)
