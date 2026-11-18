`elfcheck.parse` now uses checked integer addition when matching `DT_STRTAB` bounds against `PT_LOAD` segments so wrapping ELF headers are rejected as damaged.
