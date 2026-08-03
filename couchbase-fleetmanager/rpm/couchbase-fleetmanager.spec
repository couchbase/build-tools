# Packages the payload tree assembled by fleetmanager-rpm-build.sh, which passes it in as
# fm_stage along with fm_version and fm_release. Nothing is compiled here.

# No source is present, so leaving debuginfo generation on fails the build.
%global debug_package %{nil}
%global _build_id_links none

# Fall back if systemd-rpm-macros is missing, rather than failing on a literal
# "%{_unitdir}" path in %files.
%{!?_unitdir: %global _unitdir /usr/lib/systemd/system}

Name:           couchbase-fleetmanager
Version:        %{fm_version}
Release:        %{fm_release}%{?dist}
Summary:        Couchbase Fleet Manager
License:        Proprietary
URL:            https://www.couchbase.com/
Source0:        couchbase-fleetmanager.service
Source1:        fleetmanager.env
Source2:        credentials.json.example
Source3:        README.md
BuildRequires:  systemd-rpm-macros
Requires(pre):  shadow-utils

# No Requires/Recommends on couchbase-server, deliberately: Fleet Manager reaches Couchbase
# only over the network, so it is installable on a host managing a remote cluster. The
# relationship is expressed as systemd ordering in the unit instead.

%description
Couchbase Fleet Manager provides centralised fleet-wide visibility and management for
self-managed Couchbase Server deployments, including cluster inventory, entitlement
tracking and an activity log. It serves both the REST API and the web UI.

Fleet Manager connects to Couchbase Server over the network and may be installed either
alongside a cluster node or on a separate host. See
%{_docdir}/%{name}/README.md for configuration.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}

cp -a %{fm_stage}/. %{buildroot}/

install -Dpm 0644 %{SOURCE0} %{buildroot}%{_unitdir}/%{name}.service
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/couchbase/fleetmanager/fleetmanager.env
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_docdir}/%{name}/credentials.json.example
install -Dpm 0644 %{SOURCE3} %{buildroot}%{_docdir}/%{name}/README.md

# Created at install time so an operator can pre-seed credentials.json before first start.
mkdir -p %{buildroot}/opt/couchbase/var/lib/fleetmanager

%files
# /opt/couchbase, /opt/couchbase/var and /opt/couchbase/var/lib are deliberately unowned:
# couchbase-server owns them with its own user and modes, which we cannot match on hosts
# where it isn't installed.
%dir /opt/couchbase/fleetmanager
%dir /opt/couchbase/fleetmanager/bin
/opt/couchbase/fleetmanager/bin/fleetmanager-server
/opt/couchbase/fleetmanager/ui

%{_unitdir}/%{name}.service

%dir %attr(0750,root,fleetmanager) %{_sysconfdir}/couchbase/fleetmanager
%config(noreplace) %attr(0640,root,fleetmanager) %{_sysconfdir}/couchbase/fleetmanager/fleetmanager.env

# The directory only, not credentials.json: it is generated on first start and holds the
# only copy of both Couchbase passwords, so rpm -e must leave it behind.
%dir %attr(0700,fleetmanager,fleetmanager) /opt/couchbase/var/lib/fleetmanager

%doc %{_docdir}/%{name}/README.md
%doc %{_docdir}/%{name}/credentials.json.example

%pre
getent group fleetmanager >/dev/null || groupadd -r fleetmanager
getent passwd fleetmanager >/dev/null || \
    useradd -r -g fleetmanager -d /opt/couchbase/var/lib/fleetmanager -s /sbin/nologin \
            -c "Couchbase Fleet Manager" fleetmanager
exit 0

%post
%systemd_post %{name}.service

%preun
%systemd_preun %{name}.service

%postun
%systemd_postun_with_restart %{name}.service

%changelog
* Mon Aug 03 2026 Couchbase Build and Release Team <build-team@couchbase.com>
- Initial packaging of Couchbase Fleet Manager
