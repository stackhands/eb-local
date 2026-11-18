`eb-local lmod-cache --prefix` now falls back to `statAt` when directory entries report `DT_UNKNOWN`, allowing CPU and accelerator target discovery on filesystems without `d_type` support.
