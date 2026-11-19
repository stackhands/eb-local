The site tasks for a setuptools, meson-python, and scikit-build-core
extension read the built module with `readelf` and pass when it has a
`DT_RPATH` entry naming the stack library and no `DT_RUNPATH` entry.
The task then imports the module with no modules loaded.
