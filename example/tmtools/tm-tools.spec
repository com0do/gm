Name:           @TARGET@
Version:        @PKG_VERSION@
Release:        @PKG_RELEASE@%{?dist}
Summary:        tmctl, the telemetry command-line tool

License:        MIT
URL:            https://example.com/gm/tmd
BuildArch:      @RPM_TARGET_ARCH@
AutoReqProv:    no
Requires:       @PKG_RPM_DEPS_REQ@

%description
tmctl computes CRC-32 checksums with libtmcore and generates sample streams for tmd.
Built by gm in @BUILD_MODE@ mode.

%install
mkdir -p %{buildroot}/usr/bin %{buildroot}/usr/share/bash-completion/completions
install -m 0755 %{_sourcedir}/tmctl      %{buildroot}/usr/bin/tmctl
install -m 0644 %{_sourcedir}/tmctl.bash %{buildroot}/usr/share/bash-completion/completions/tmctl

%files
/usr/bin/tmctl
/usr/share/bash-completion/completions/tmctl

%changelog
* Tue Oct 20 2026 gm example <gm@example.com> - 1.4.0-1
- tmctl crc, tmctl wave
