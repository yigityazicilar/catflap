Name: catflap
Version: %{catflap_version}
Release: 1%{?dist}
Summary: Private clipboard history and transfers between your own devices
License: BSD-3-Clause
URL: https://github.com/yigityazicilar/catflap
# The official Fedora toolchain uses the distro's native legacy XML provider.
# It is deliberately not a runtime Requires.
BuildRequires: libxml2_2.13
Requires: gtk4-layer-shell >= 1.0.4
# Derive native ABI requirements automatically, excluding only private libraries.
%global __requires_exclude ^(libswift|libFoundation|lib_Foundation|libdispatch|libBlocksRuntime|libtailcat)
%global __provides_exclude_from ^/usr/lib/catflap/.*
%global debug_package %{nil}
%global __os_install_post %{nil}

%description
GTK panel and command-line agent with private Swift runtime libraries.

%install
mkdir -p %{buildroot}
cp -a %{payload}/. %{buildroot}/

%files -f %{_sourcedir}/files.list
