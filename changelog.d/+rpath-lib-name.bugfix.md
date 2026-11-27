The run path wrapper recorded a plugin named `plugin.so` inside `lib64`.
The loader searches `lib64` first and can open the wrong library.
The wrapper now records a run path only for a file name starting with `lib`.
