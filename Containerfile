ARG FEDORA=44

# ---------- common: shared base, no user ----------
FROM quay.io/fedora/fedora-bootc:${FEDORA} AS common

# Network, LUKS + TPM2 support in the initramfs
RUN dnf -y install NetworkManager-wifi NetworkManager-tui cryptsetup \
        tpm2-tools tpm2-tss authselect openssl linux-firmware && \
    dnf clean all
RUN mkdir -p /usr/lib/dracut/dracut.conf.d && \
    echo 'add_dracutmodules+=" crypt tpm2-tss "' > /usr/lib/dracut/dracut.conf.d/60-luks-tpm2.conf && \
    kver=$(cd /usr/lib/modules && echo *) && \
    dracut -vf --no-hostonly --kver "$kver" "/usr/lib/modules/$kver/initramfs.img"


# ---------- install: small image for the live USB install ----------
FROM common AS install
ARG USERNAME
ARG PASSWORD_HASH
RUN test -n "$USERNAME" && test -n "$PASSWORD_HASH" && \
    useradd -m -u 1000 -G wheel -s /bin/bash "$USERNAME" && \
    usermod -p "$PASSWORD_HASH" "$USERNAME"
RUN bootc container lint


# ---------- desktop: the part you'll publish later. NO user, NO secrets ----------
FROM common AS desktop

# KDE Plasma, fingerprint, keyring
# (confirm the group name with: dnf group list --hidden | grep -i kde)
RUN dnf -y group install kde-desktop-environment && \
    dnf -y install fprintd fprintd-pam gnome-keyring gnome-keyring-pam seahorse && \
    dnf clean all

RUN systemctl enable sddm.service && \
    systemctl set-default graphical.target && \
    (authselect select local with-fingerprint with-pam-gnome-keyring --force || \
     authselect select sssd  with-fingerprint with-pam-gnome-keyring --force)

# Microsoft Edge (+ optional Intune). Microsoft packages install to /opt,
# which bootc doesn't update, so relocate them into /usr.
ARG WITH_INTUNE=0
RUN mkdir -p /var/opt && \
    rpm --import https://packages.microsoft.com/keys/microsoft.asc && \
    printf '[microsoft-edge]\nname=Microsoft Edge\nbaseurl=https://packages.microsoft.com/yumrepos/edge\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' > /etc/yum.repos.d/microsoft-edge.repo && \
    dnf -y install microsoft-edge-stable && \
    if [ "$WITH_INTUNE" = "1" ]; then \
      for v in 44 43 42 41 40; do \
        curl -fsSL "https://packages.microsoft.com/config/fedora/$v/prod.repo" -o /etc/yum.repos.d/microsoft-prod.repo && break; \
      done && \
      dnf -y install intune-portal; \
    fi && \
    dnf clean all && \
    if [ -d /var/opt/microsoft ]; then \
      mkdir -p /usr/lib/opt && mv /var/opt/microsoft /usr/lib/opt/microsoft && \
      printf 'd /var/opt 0755 root root -\nL+ /var/opt/microsoft - - - - /usr/lib/opt/microsoft\n' > /usr/lib/tmpfiles.d/microsoft-opt.conf; \
    fi

RUN bootc container lint


# ---------- local: what you actually run (desktop + your user) ----------
# When you start using a registry, change the next line to:
#   FROM ghcr.io/YOU/fw13:desktop AS local
FROM desktop AS local
ARG USERNAME
ARG PASSWORD_HASH
RUN test -n "$USERNAME" && test -n "$PASSWORD_HASH" && \
    useradd -m -u 1000 -G wheel -s /bin/bash "$USERNAME" && \
    usermod -p "$PASSWORD_HASH" "$USERNAME"
RUN bootc container lint
