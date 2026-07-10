Name:           @TARGET@
Version:        @PKG_VERSION@
Release:        @PKG_RELEASE@%{?dist}
Summary:        sample package bundling t3 + libt2

License:        MIT
URL:            https://example.com
BuildArch:      @RPM_TARGET_ARCH@
AutoReqProv:    no
Requires:       @PKG_RPM_DEPS_REQ@

%description
Sample RPM produced by gm's target.pkg.mk.  Built in @BUILD_MODE@ mode
on @BUILD_ARCH@.  Bundles the t3 executable and libt2 shared library
from the same build tree.

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib64
mkdir -p %{buildroot}/etc/p1
install -m 0755 %{_sourcedir}/t3       %{buildroot}/usr/bin/t3
install -m 0644 %{_sourcedir}/libt2.so %{buildroot}/usr/lib64/libt2.so
install -m 0644 %{_sourcedir}/p1.conf  %{buildroot}/etc/p1/p1.conf

%files
/usr/bin/t3
/usr/lib64/libt2.so
%config(noreplace) /etc/p1/p1.conf

%changelog
* Mon Jan 01 2024 cyrus <cyrus.cui@nokia.com> - 1.0.0-1
- initial package
