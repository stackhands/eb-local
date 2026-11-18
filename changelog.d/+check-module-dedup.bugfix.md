`eb-local check --module` now deduplicates installation roots before auditing ELF files, so repeating a module argument no longer audits files twice or doubles `problem_count` and `elf_count`.
