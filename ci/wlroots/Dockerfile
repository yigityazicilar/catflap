FROM golang:1.27.3 AS go
FROM swift:6.2.1-noble
COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sway libwlroots12t64 wayland-utils wl-clipboard wtype dbus-x11 python3 libsqlite3-dev libgtk-4-dev libadwaita-1-dev libwayland-dev wayland-protocols libgirepository1.0-dev gobject-introspection meson ninja-build pkg-config git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch v1.0.4 https://github.com/wmww/gtk4-layer-shell.git /opt/layer-shell && meson setup /opt/layer-shell/out /opt/layer-shell -Dexamples=false -Ddocs=false -Dtests=false -Dintrospection=false -Dvapi=false --prefix=/usr/local && ninja -C /opt/layer-shell/out install && ldconfig && rm -rf /opt/layer-shell
ENTRYPOINT ["python3", "/src/ci/wlroots/run.py"]
