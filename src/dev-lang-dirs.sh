# A caller who set either variable, even to empty, keeps that value.
# ${name+x} and ${name-} do not trip nounset when the variable is unset.
if [ -z "${JULIA_DEPOT_PATH+x}" ] && [ -n "${EB_LOCAL_DEV_PREFIX-}" ]; then
  # A trailing colon keeps Julia's bundled depots after this one.
  export JULIA_DEPOT_PATH="${EB_LOCAL_DEV_PREFIX}/julia:"
fi
if [ -z "${R_LIBS_USER+x}" ] && [ -n "${EB_LOCAL_DEV_PREFIX-}" ]; then
  # R expands %p to its platform and %v to major.minor, its own library layout.
  export R_LIBS_USER="${EB_LOCAL_DEV_PREFIX}/R/%p-library/%v"
fi
if [ -z "${PYTHONUSERBASE+x}" ] && [ -n "${EB_LOCAL_DEV_PREFIX-}" ]; then
  # pip's user install writes under this directory, per Python version.
  export PYTHONUSERBASE="${EB_LOCAL_DEV_PREFIX}/python"
fi
if [ -n "${EB_LOCAL_DEV_GO_PREFIX-}" ]; then
  case ${GOPATH-} in "${EB_LOCAL_DEV_GO_PREFIX}/go") unset GOPATH ;; esac
  case ${GOMODCACHE-} in "${EB_LOCAL_DEV_GO_PREFIX}/go/pkg/mod") unset GOMODCACHE ;; esac
fi
if [ -n "${EB_LOCAL_DEV_PREFIX-}" ]; then
  if [ -z "${GOPATH+x}" ] && [ -z "${GOMODCACHE+x}" ]; then
    GOPATH="${EB_LOCAL_DEV_PREFIX}/go"
    GOMODCACHE="${GOPATH}/pkg/mod"
  elif [ -z "${GOPATH+x}" ]; then
    case ${GOMODCACHE} in
      ?*/pkg/mod) GOPATH=${GOMODCACHE%/pkg/mod} ;;
      *) GOPATH="${EB_LOCAL_DEV_PREFIX}/go" ;;
    esac
  elif [ -z "${GOMODCACHE+x}" ] && [ -n "${GOPATH%%:*}" ]; then
    GOMODCACHE="${GOPATH%%:*}/pkg/mod"
  fi
  export GOPATH
  if [ -n "${GOMODCACHE+x}" ]; then export GOMODCACHE; fi
  export EB_LOCAL_DEV_GO_PREFIX="${EB_LOCAL_DEV_PREFIX}"
fi
