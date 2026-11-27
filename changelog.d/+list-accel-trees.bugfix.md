The list command omitted modules that sit under an accelerator tree.
It stopped at the CPU directory, so a module built for `accel/nvidia/cc90` never appeared.
The same command now includes that tree, and `EESSI_ACCELERATOR_TARGET` selects its column.
