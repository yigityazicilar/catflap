FROM archlinux:latest
RUN pacman -Syu --noconfirm --needed gnome-shell mutter dbus gjs glib2 gtk4 libadwaita gtk4-layer-shell wayland-utils wl-clipboard python python-gobject jq git go clang pkgconf sqlite libxml2 libedit ncurses curl gcc-libs \
 && pacman -Scc --noconfirm
RUN mkdir -p /opt/swift && curl -fL --retry 3 https://download.swift.org/swift-6.2.1-release/ubuntu2404/swift-6.2.1-RELEASE/swift-6.2.1-RELEASE-ubuntu24.04.tar.gz | tar xz -C /opt/swift --strip-components=1
RUN pacman -S --noconfirm --needed diffutils gcc make libxml2-legacy && pacman -Scc --noconfirm \
 && ln -s libncursesw.so.6 /usr/lib/libncurses.so.6
ENV PATH="/opt/swift/usr/bin:${PATH}"
RUN dbus-uuidgen --ensure=/etc/machine-id && mkdir -p /var/lib/dbus && ln -sf /etc/machine-id /var/lib/dbus/machine-id
COPY session.sh /usr/local/bin/gnome-session-test
RUN chmod 755 /usr/local/bin/gnome-session-test
ENV XDG_RUNTIME_DIR=/run/gnome-test HOME=/root
WORKDIR /repo
ENTRYPOINT ["/usr/local/bin/gnome-session-test"]
