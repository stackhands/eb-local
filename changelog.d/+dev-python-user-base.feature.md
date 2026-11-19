`eb-local dev` sets `PYTHONUSERBASE` under `EB_LOCAL_DEV_PREFIX` when the caller has not set it, so pip's user install stays on that CPU target. An empty value is left as the caller set it.
