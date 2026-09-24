# Framework 13 Pro: Fedora bootc install

Bootstrapping the Framework 13 Pro from a Fedora Live USB into a bootc-managed
KDE system with LUKS + TPM2 disk encryption. Everything is done on the laptop
itself.

Referenced files (already in this repo, not duplicated here):

- `Containerfile` — defines two stages: `install` (a one-time, local-only
  bootstrap image used from the Live USB) and `desktop` (the real system —
  built locally for first boot, and later the exact image you publish to a
  registry, unchanged).
- `/etc/containers/policy.json`, `/etc/containers/registries.d/*.yaml` —
  added later, once publishing to a registry (Phase 8).

**How the account works:** the account is declared via a `systemd-sysusers`
config file shipped in `/usr/lib/sysusers.d/`, part of the versioned image
rather than the mutable `/etc` that bootc merges across upgrades — this is a
defensive baseline, so the account still gets (re-)created at boot on *any*
future image built from `desktop`, including one with no local build at all.

That declaration alone isn't enough on its own, though: `sysusers.d` doesn't
set a password, and the very first switch away from `install` treats an
untouched account as "unmodified" and can adopt the new image's own default
`/etc/passwd` wholesale — wiping the account rather than just resetting its
password, since the account never existed in the destination image's own
baked default at all. So `desktop` also materializes the account at build
time — unconditionally, regardless of whether a password is supplied — so
its own default `/etc/passwd` always has it. `PASSWORD_HASH` itself is only
required for `install` (nothing has logged in anywhere yet, so it's the only
way to get through the very first boot) and optional for `desktop`: set your
real password once via `passwd` while still on `install`, and it becomes a
genuine local edit that keeps winning over anything rebaked into `desktop`
afterward — so `desktop` builds don't need `PASSWORD_HASH` at all from then
on. Revisit this before actually publishing `desktop` to a registry
(Phase 8): a shared image shouldn't carry a personal password hash even as
an optional argument.

---

## Phase 0 — Prerequisites

- [ ] Enable Secure Boot in the BIOS (F2 at boot → Security → Secure Boot)
      and leave it in its final state before continuing — TPM unlock
      binds to this state.
- [ ] Get a current Fedora Workstation Live USB (Fedora 44 or later —
      not 41, which is EOL).
- [ ] Decide on a LUKS passphrase (temporary fallback until TPM unlock is
      enrolled) and a login username.
- [ ] Boot the USB (F12 → select USB → Try Fedora), connect to Wi-Fi, open
      a terminal.
- [ ] `git clone` this repo (with `Containerfile`) onto the Live USB
      session.

---

## Phase 1 — Partition, encrypt, format (on the Live USB)

Identify the internal disk before doing anything else:

```bash
lsblk
DISK=/dev/nvme0n1   # confirm this is the internal disk, NOT the USB stick
```

Partition into EFI, `/boot`, and root using `sfdisk` (part of `util-linux`,
already on the Live image — unlike `sgdisk`/`gdisk`, which usually isn't):

```bash
sudo sfdisk --wipe always $DISK <<EOF
label: gpt

size=1GiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
size=1GiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="boot"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"
EOF
```

(`C12A7328-...` is the standard EFI System Partition type GUID;
`0FC63DAF-...` is the generic Linux filesystem type GUID — used here for
both `/boot` and the LUKS partition, since this guide addresses
partitions by UUID/kernel args rather than relying on type-based
auto-discovery.)

Encrypt the root partition and open it:

```bash
sudo cryptsetup luksFormat --type luks2 ${DISK}p3
sudo cryptsetup open ${DISK}p3 root_crypt
```

Format each partition:

```bash
sudo mkfs.vfat -F32 -n EFI ${DISK}p1
sudo mkfs.ext4 -L boot ${DISK}p2
sudo mkfs.xfs  -L root /dev/mapper/root_crypt
```

- [ ] Verify with `lsblk` that `root_crypt` appears under the root
      partition.

---

## Phase 2 — Build the install image (on the Live USB)

From the repo directory (containing `Containerfile`):

The Containerfile installs the `kde-desktop` group. If your Fedora
release changed and that group is missing, check what's available:

```bash
dnf group list --hidden | grep -i kde
```

Build the `install` stage only, as root, so KDE isn't pulled into the
RAM-limited Live session. Generate the hash *inside* this same command with
`$(...)` — don't run `openssl passwd -6` separately and paste the result
in, since the shell will mangle the `$` characters in a pasted hash (`$6`
looks like a positional parameter, the next `$word` looks like a variable
name) and silently corrupt it:

```bash
sudo podman build --target install \
  --build-arg USERNAME="yourname" \
  --build-arg PASSWORD_HASH="$(openssl passwd -6)" \
  -t localhost/fw13:install .
```

Verify the image exists:

```bash
sudo podman images
```

Optional — confirm the account and password hash landed correctly
(expect a `$6$...$...` hash and status `P`, not `L` or `NP`):

```bash
sudo podman run --rm localhost/fw13:install grep '^yourname:' /etc/shadow
sudo podman run --rm localhost/fw13:install passwd -S yourname
```

- [ ] Optional: review `bootc container lint` output from the build. Since
      the account comes from a `sysusers.d` entry rather than a bare
      `useradd`, the `sysusers` warning seen in earlier drafts of this
      image should no longer appear. Warnings about `/run` or `/var/log`
      are still expected and not blocking.

---

## Phase 3 — Install to the encrypted disk (on the Live USB)

Mount the target, with `/boot` and the EFI partition inside it:

```bash
sudo mkdir -p /mnt/target
sudo mount /dev/mapper/root_crypt /mnt/target
sudo mkdir -p /mnt/target/boot
sudo mount ${DISK}p2 /mnt/target/boot
sudo mkdir -p /mnt/target/boot/efi
sudo mount ${DISK}p1 /mnt/target/boot/efi
```

Install, passing LUKS unlock kernel args built from the partition's UUID
(this replaces any crypttab edit — bootc doesn't read `/etc/crypttab`
from outside the deployed OS):

```bash
LUKS_UUID=$(sudo blkid -s UUID -o value ${DISK}p3)

sudo podman run --rm --privileged --pid=host \
  --security-opt label=type:unconfined_t \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  -v /mnt/target:/target \
  localhost/fw13:install \
  bootc install to-filesystem \
    --karg=rd.luks.name=${LUKS_UUID}=root_crypt \
    --karg=rd.luks.options=${LUKS_UUID}=tpm2-device=auto \
    /target
```

Clean up and reboot:

```bash
sync
sudo umount -R /mnt/target
sudo cryptsetup close root_crypt
sudo systemctl reboot     # remove the USB
```

---

## Phase 4 — First boot: build the full KDE image

- [ ] Unlock the disk with the LUKS passphrase at boot.
- [ ] Log in on the text console with your username/password (this is the
      password baked into `install`).
- [ ] Bring up networking with `nmtui`, then confirm connectivity, e.g.
      `ping -c1 fedoraproject.org`.
- [ ] Set your real password **now, while still on `install`**, before
      building or switching to anything:

  ```bash
  passwd
  ```

  This is what makes the rest of this phase simpler: once your password
  is a genuine local edit, it keeps winning over anything baked into
  future builds, so `desktop`'s build no longer needs a password at all.
- [ ] Do **not** run `useradd`, or otherwise hand-edit `/etc/passwd`,
      before the switch below — the upcoming `/etc` merge can lock out
      accounts created outside the image.

`git clone` the repo into your home directory and build the `desktop`
stage. No `PASSWORD_HASH` needed this time, since your real password is
already set locally and will carry over:

```bash
git clone <repo-url> ~/fw13 && cd ~/fw13

sudo podman build --target desktop \
  --build-arg USERNAME="$USER" \
  -t localhost/fw13:desktop .
```

Switch to it and reboot:

```bash
sudo bootc switch --transport containers-storage localhost/fw13:desktop
sudo systemctl reboot
```

- [ ] If the new image fails to boot: select the previous entry in the
      GRUB menu, then run `sudo bootc rollback`.
- [ ] After reboot, confirm you land on the graphical login screen
      (Plasma's `plasmalogin`, not SDDM — see the Containerfile note in
      Phase 2) and can log in with the password you set above.

---

## Phase 5 — TPM2 auto-unlock + recovery key

Only once the desktop boots correctly and Secure Boot is in its final
state.

Enroll a recovery key (write it down somewhere safe outside the
laptop):

```bash
sudo systemd-cryptenroll --recovery-key /dev/nvme0n1p3
```

Bind unlock to the TPM, keyed to PCR 7 only (Secure Boot state — not PCR
0, which changes on firmware updates and would break unlock):

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p3
```

Optional PIN — without one, anyone with the laptop reaches the login
screen without a passphrase: add `--tpm2-with-pin=yes` to the command
above.

Confirm the enrolled slots (want: password, recovery, tpm2):

```bash
sudo systemd-cryptenroll /dev/nvme0n1p3
```

- [ ] Reboot and confirm the disk unlocks with no prompt.
- [ ] Know the recovery path: a BIOS/Secure Boot change invalidates the
      TPM binding — enter the passphrase or recovery key, then re-enroll:

  ```bash
  sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p3
  ```

---

## Phase 6 — Fingerprint

```bash
fprintd-enroll
fprintd-verify
```

- [ ] Note the limitation: fingerprint login can't unlock gnome-keyring
      (there's no password behind it) — log in with your password when
      you need the keyring/Edge to unlock.

---

## Phase 7 — Edge and Intune

- [ ] Confirm Edge launches and uses the gnome-keyring. If it tries
      KWallet instead, launch with:

  ```bash
  microsoft-edge-stable --password-store=gnome-libsecret
  ```

- [ ] Before relying on Intune: confirm with IT whether a Fedora/KDE
      client is acceptable — Microsoft's Linux client officially targets
      Ubuntu/RHEL with GNOME, so enrollment or compliance may fail.

To try it, rebuild `desktop` with the Intune flag and upgrade in place.
No `PASSWORD_HASH` needed, since your real password (Phase 4) is already
a local edit and carries over on its own:

```bash
sudo podman build --target desktop --build-arg WITH_INTUNE=1 \
  --build-arg USERNAME="$USER" \
  -t localhost/fw13:desktop .
sudo bootc upgrade
sudo systemctl reboot
```

- [ ] Sign in via Intune Portal from the application launcher.
- [ ] Make sure a default keyring with a password exists (via the
      installed keyring-management app) since KDE's session isn't GNOME.

---

## Day-to-day updates

Edit the Containerfile as needed, then:

```bash
sudo podman build --target desktop \
  --build-arg USERNAME="$USER" \
  -t localhost/fw13:desktop .
sudo bootc upgrade
sudo systemctl reboot
```

---

## Phase 8 — Later: registry + signing

Once the base system is stable and you're ready to publish. Because
`desktop` is already the exact image you're running — no separate "local"
overlay needed — this is the last local build you'll do; every update
after this is a straight `bootc upgrade` against the registry.

Generate a sigstore key pair (key-based signing, not keyless — keyless
verification has known gaps with some CI-issued certificates):

```bash
skopeo generate-sigstore-key --output-prefix fw13-sign
```

- [ ] Back up `fw13-sign.private` somewhere outside any image; keep
      `fw13-sign.pub` for the laptop's trust policy.

Build and push `desktop`, signed:

```bash
sudo podman build --target desktop --build-arg USERNAME="$USER" \
  -t localhost/fw13:desktop .
sudo podman login ghcr.io
sudo podman push --sign-by-sigstore-private-key ./fw13-sign.private \
  localhost/fw13:desktop docker://ghcr.io/YOU/fw13:desktop
```

- [ ] On the laptop, install `fw13-sign.pub` and add the registry's trust
      policy (`policy.json` + `registries.d`) so unsigned or
      wrongly-signed pulls of that image are rejected.
- [ ] Test the failure case deliberately: push an unsigned tag and
      confirm the laptop refuses to pull it.
- [ ] Point the laptop at the registry image and confirm no local build
      is needed to stay updated:

  ```bash
  sudo bootc switch docker://ghcr.io/YOU/fw13:desktop
  sudo systemctl reboot
  ```

  After this, `sudo bootc upgrade` alone pulls new signed builds — your
  account and password persist automatically via the mechanism described
  at the top of this file.
- [ ] When ready, move image builds to CI so pushes are automated instead
      of run from your own machine.
