#!/bin/bash
# appDockerInstaller.sh -- in-container DSL interpreter.
#
# Reads /root/container/installGuide.in line by line and executes:
#   [RPMINSTALL]   <pkg ...>   -> yum install -y <pkg ...>
#   [RPMUNINSTALL] <pkg ...>   -> yum remove -y <pkg ...>
#   [RUN]          <shell cmd> -> eval <cmd>
#   [START]                      starts execution
#   [STOP]                       ends execution + final cleanup
#
# This is the **generic** version of the legacy
# `reg_container_tooling/4g_Containers/buildTools/appDockerInstaller.sh`
# -- same DSL grammar but stripped of target-service-specific cleanup logic
# (which lives there as `cleanUpOsUser.sh`, `siftesterInstrument.sh`,
# etc., and can be wired back in by sourcing them from a [RUN] block
# in the manifest's installGuide.in).
#
# Yum repos are pre-staged into /root/container/container.repo by
# container's BuildContext.

set -e

# Pick whichever package manager is actually available in the base
# image: yum (RHEL 7), dnf (RHEL 8+/Fedora), or microdnf (ubi-minimal).
# All three accept the same `install/remove -y` verbs we use, so the
# rest of this script doesn't care which one we picked.
PM=""
for cmd in yum dnf microdnf; do
    if command -v "$cmd" >/dev/null 2>&1; then
        PM="$cmd"; break
    fi
done
if [ -z "$PM" ]; then
    echo "container: no yum/dnf/microdnf in base image; cannot install RPMs" >&2
    PM="false"
fi

PM_INSTALL_OPTIONS="-y"
case "$PM" in
    yum|dnf) PM_INSTALL_OPTIONS="-y --nodocs --setopt=install_weak_deps=False" ;;
esac

if [ -f /root/container/container.repo ]; then
    cp /root/container/container.repo /etc/yum.repos.d/container.repo
fi

# Optional: honour a versionlock.list (from `--rpm-lock` at build
# time) so subsequent RPMINSTALL commands install these exact
# versions instead of "whatever the yum repo currently serves".
# Format matches the reg framework:  name-0:version-release.arch
if [ -f /root/container/versionlock.list ] && \
   [ "$PM" != "microdnf" ] && [ "$PM" != "false" ]; then
    $PM install -y yum-plugin-versionlock 2>/dev/null || \
    $PM install -y python3-dnf-plugin-versionlock 2>/dev/null || true
    mkdir -p /etc/yum
    cp /root/container/versionlock.list /etc/yum/versionlock.list
    printf "[main]\nenabled=1\nlocklist=/etc/yum/versionlock.list\n" \
        >> /etc/yum/pluginconf.d/versionlock.conf 2>/dev/null || true
fi

# Prep container runtime -- install the manifest's `prerequisites:`
# BEFORE the user's installGuide.in blocks run.  This is where
# `python3 tar findutils vim-minimal gzip` typically go (equivalent
# of reg's hard-coded yum install at the top of appDockerInstaller.sh).
if [ -s /root/container/prerequisites.list ] && [ "$PM" != "false" ]; then
    echo "container: installing prerequisites ($PM $PM_INSTALL_OPTIONS install)"
    prereqs=$(tr '\n' ' ' < /root/container/prerequisites.list)
    $PM $PM_INSTALL_OPTIONS install $prereqs
fi

action=""
startTagFound=0

finishImageCreation() {
    $PM clean all 2>/dev/null || true
    rm -rf /var/cache/dnf /var/lib/dnf /var/lib/yum 2>/dev/null || true
    rm -rf /root/container
}

snapshotPackageList() {
    if command -v rpm >/dev/null 2>&1; then
        rpm -qa --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' \
            2>/dev/null | sort > /tmp/container.snap || true
    fi
}

GUIDE=/root/container/installGuide.in
if [ ! -f "$GUIDE" ]; then
    echo "container: no installGuide.in found -- nothing to install"
    finishImageCreation
    exit 0
fi

while IFS= read -r raw || [ -n "$raw" ]; do
    item=$(echo "$raw" | sed 's/^\s\+//;s/\s\+$//')
    [ -z "$item" ] && continue
    case "$item" in
        \#*|\**) continue ;;
    esac

    if [ "$item" = "[STOP]" ]; then
        finishImageCreation
        exit 0
    fi
    if [ "$startTagFound" = "0" ] && [ "$item" = "[START]" ]; then
        startTagFound=1
        snapshotPackageList
        continue
    fi
    [ "$startTagFound" = "0" ] && continue

    case "$item" in
        \[*\]) action="$item" ; continue ;;
    esac

    case "$action" in
        "[RPMINSTALL]")
            $PM $PM_INSTALL_OPTIONS install $item ;;
        "[RPMUNINSTALL]")
            $PM -y remove $item ;;
        "[RUN]")
            echo "Executing: $item"
            eval "$item" ;;
        *)
            echo "container: unknown action '$action' (line ignored): $item" >&2 ;;
    esac
done < "$GUIDE"

# Implicit STOP if the file ends without one
finishImageCreation
