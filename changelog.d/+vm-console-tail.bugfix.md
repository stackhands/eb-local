A failed `kvm` run prints the last 2000 bytes of `console.log` from `eb-local __vm-run`.
A log longer than one mebibyte used to print none of that tail.
The read now starts at the end of the file.
