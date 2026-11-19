if ! type module >/dev/null 2>&1; then
    if [ -n "${ZSH_VERSION-}" ]; then
        eb_local_shell=zsh
    elif [ -n "${BASH_VERSION-}" ]; then
        eb_local_shell=bash
    else
        eb_local_shell="sh"
    fi
    eb_local_profile_init=
    if [ "$eb_local_shell" = bash ]; then
        eb_local_profile_init=/etc/profile.d/lmod.sh
    fi
    for eb_local_init in "${LMOD_PKG:-/usr/share/lmod/lmod}/init/$eb_local_shell" "$eb_local_profile_init" \
        "${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}/versions/${EESSI_VERSION:-2026.06}/init/lmod/$eb_local_shell"; do
        # shellcheck source=/dev/null
        [ -n "$eb_local_init" ] && [ -f "$eb_local_init" ] && [ -r "$eb_local_init" ] && { . "$eb_local_init" >/dev/null; break; }
    done
    unset eb_local_init eb_local_profile_init eb_local_shell
fi
