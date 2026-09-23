ARG FEDORA=44
ARG USERNAME

# ---------- common: shared base + declarative account, no password ----------
FROM quay.io/fedora/fedora-bootc:${FEDORA} AS common
ARG USERNAME

# Network, LUKS + TPM2 support in the initramfs
# Sync to Fedora's current `updates` repo rather than trusting whatever
# snapshot the base image was pinned to -- this is what actually keeps
# kernel/firmware pairings (and everything else) current on every future
# rebuild, not just this one.
RUN dnf -y update && dnf clean all

RUN dnf -y install NetworkManager-wifi NetworkManager-tui cryptsetup \
        tpm2-tools tpm2-tss authselect openssl linux-firmware \
        iwlwifi-mvm-firmware git && \
    dnf clean all
RUN mkdir -p /usr/lib/dracut/dracut.conf.d && \
    echo 'add_dracutmodules+=" crypt tpm2-tss "' > /usr/lib/dracut/dracut.conf.d/60-luks-tpm2.conf && \
    kver=$(cd /usr/lib/modules && ls -1 | sort -V | tail -1) && \
    dracut -vf --no-hostonly --kver "$kver" "/usr/lib/modules/$kver/initramfs.img"

# Declare the interactive user account via systemd-sysusers rather than
# useradd. This file lives in /usr, not /etc, so it isn't subject to
# bootc's /etc 3-way merge on upgrade: systemd-sysusers re-applies it at
# every boot, so the account exists on ANY image built FROM this stage --
# including a bare `desktop` image pulled straight from a registry with
# no local build. sysusers.d never sets a password; that's handled
# separately (see the `install` stage, and `passwd` after first login).
RUN test -n "$USERNAME" && \
    mkdir -p /usr/lib/sysusers.d /usr/lib/tmpfiles.d && \
    printf 'u %s 1000 "%s" /var/home/%s /bin/bash\nm %s wheel\n' \
      "$USERNAME" "$USERNAME" "$USERNAME" "$USERNAME" \
      > "/usr/lib/sysusers.d/10-${USERNAME}.conf" && \
    printf 'd /var/home/%s 0700 %s %s - -\n' \
      "$USERNAME" "$USERNAME" "$USERNAME" \
      > "/usr/lib/tmpfiles.d/10-${USERNAME}-home.conf"


# ---------- install: one-time Live USB bootstrap image. Local only, never published. ----------
FROM common AS install
ARG USERNAME
ARG PASSWORD_HASH
# Force-create the account now (systemd-sysusers normally runs at boot,
# not build time) so we can bake in a password to get through the very
# first login. Replace this password with `passwd` after first boot --
# from then on it's a local edit that survives every future switch.
RUN test -n "$USERNAME" && test -n "$PASSWORD_HASH" && \
    systemd-sysusers && \
    usermod -p "$PASSWORD_HASH" "$USERNAME"
RUN bootc container lint


# ---------- desktop: the real system. Same image whether built locally or published. No secrets. ----------
FROM common AS desktop

# KDE Plasma, fingerprint, keyring
RUN dnf -y group install kde-desktop && \
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
