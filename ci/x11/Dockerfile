# The X11 test session: Ubuntu 24.04 (the release of the CI runners) with Swift 6.2.1,
# Catflap's build dependencies, and the X server, window manager and input tools the X11
# tests drive: Xvfb, xfwm4 (with xfconf, to switch on its focus-stealing prevention), and
# xdotool, which types and moves the pointer through XTEST.
FROM swift:6.2.1-noble
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libsqlite3-dev libgtk-4-dev libadwaita-1-dev libwayland-dev wayland-protocols \
        libx11-dev libxfixes-dev meson ninja-build pkg-config gcc libc6-dev git ca-certificates curl \
        python3 procps dbus dbus-daemon xvfb xfwm4 xfconf xdotool xclip x11-utils \
    && rm -rf /var/lib/apt/lists/*
# The same gtk4-layer-shell the Linux CI job builds: the Linux targets link it on every desktop.
RUN git clone --depth 1 --branch v1.0.4 https://github.com/wmww/gtk4-layer-shell.git /tmp/gtk4-layer-shell \
    && meson setup /tmp/gtk4-layer-shell/out /tmp/gtk4-layer-shell -Dexamples=false -Ddocs=false -Dtests=false \
        -Dintrospection=false -Dvapi=false --prefix=/usr/local --libdir=lib/x86_64-linux-gnu \
    && ninja -C /tmp/gtk4-layer-shell/out install && ldconfig && rm -rf /tmp/gtk4-layer-shell
# Go builds libtailcat (scripts/build-libtailcat.sh); the version the CI jobs use.
RUN curl -fsSL -o /tmp/go.tar.gz https://go.dev/dl/go1.27.3.linux-amd64.tar.gz \
    && echo "65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40  /tmp/go.tar.gz" | sha256sum -c - \
    && tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz
ENV PATH=/usr/local/go/bin:$PATH
