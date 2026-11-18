`eb-local-readiness` now selects the latest covering mount entry in `mountinfo` when multiple mounts share the same target path, matching `storage.mountOf` when `cvmfs` overlays `autofs`.
