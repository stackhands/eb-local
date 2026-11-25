Pin `zig-common` to `a45142a`, the `develop` merge of `zig-common` #89,
where `state.RootLock.release` returns `sys.Error!void`. eb-local takes no
`RootLock`, so no call site changes. A failed write in `lmod-cache`,
`modulerc` and `overlay materialize` reports Python's `[Errno N] ...`
text, with the file it names, where it used to print the error name such
as `NoSpace` or `AccessDenied`; `site`, `submit` and
`doctor` add that file name to the errno text they already printed.
