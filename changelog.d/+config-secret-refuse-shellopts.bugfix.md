`config.validSecretName` now refuses `SHELLOPTS` and `BASHOPTS` alongside `BASH_ENV` and `ENV` so secret entries cannot inject shell startup options into build commands.
