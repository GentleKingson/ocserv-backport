# Build Host Bootstrap (spec §6.1)

One-time setup on the dedicated trixie amd64 builder (user `builder`).

## 1. Packages
sudo apt install -y sbuild schroot debootstrap \
  build-essential devscripts debhelper debhelper-compat \
  dpkg-dev fakeroot lintian quilt \
  rclone aptly gnupg jq docker.io git curl ca-certificates

## 2. trixie sbuild chroot (sources: trixie / trixie-updates / trixie-security ONLY)
sudo sbuild-createchroot --arch=amd64 --components=main \
  trixie /var/lib/sbuild/trixie-amd64-sbuild http://deb.debian.org/debian
# Verify sources.list has NO sid/testing; edit if needed.

## 3. GPG signing key (local, never leaves this host)
gpg --generate-key          # dedicated backport signing key
KEYID=...
gpg --armor --export "${KEYID}" > ansible/roles/ocserv_backport/files/thehkus-backports.asc
# Put passphrase into GitHub secret GPG_PASSPHRASE.

## 4. aptly init
aptly config edit   # set gpgKey=<KEYID>, rootDir=/var/aptly
sudo mkdir -p /var/aptly/{public/{testing,prod},.locks,state}
sudo chown -R builder:builder /var/aptly
aptly repo create ocserv-backports

## 5. rclone remote skeleton (NO secrets here)
# scripts/r2-sync.sh injects RCLONE_CONFIG_R2_* at runtime from CI secrets.

## 6. GitHub self-hosted runner
# Register runner with labels [self-hosted, builder], as user `builder`.

## 7. GitHub secrets (repo or environment level)
# R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ACCOUNT_ID, R2_BUCKET
# CF_API_TOKEN, CF_ZONE_ID, GPG_PASSPHRASE
# (GPG private key, aptly DB, staging/prod SSH keys are NEVER GitHub secrets.)

## 8. Backups (spec §6.1 [10])
# /var/aptly, /var/aptly/state, ~/.gnupg, /etc/schroot/chroot.d/, rclone.conf, runner config.

## Verify with dry-run
make -C <repo> dry-run
