Run the live EESSI 2026.06 checks in `tests/site/test_dev_locked_eessi.py`
outside `python3 -m unittest discover -s tests`. `tests/site` is not a
package, so the zero-skip `zig` job does not collect them. Running the
file fails when the Zig build or the EESSI init file is absent.
