# Ephemeral ci-build Runner — Operator Runbook (Phase 1, IPv4-only)

Phase 1 ships a **manually-triggered, single-slot** ephemeral runner for the
`lock-projection` job. NOT an autoscaler. One operator action → one runner
container → one job → bounded wait → auto-deregister → auto-remove.

## Image supply chain + refresh SLA

```text
build host:
  make runner-image TRIXIE_DIGEST=docker.io/library/debian@sha256:<64hex> \
                    RUNNER_TARBALL_URL=<actions-runner tarball URL> \
                    RUNNER_TARBALL_SHA256=<64hex sha256 of that tarball>
  → buildx build + push to registry; prints the registry MANIFEST digest
    (NOT RepoDigests of a local-only build; use buildx imagetools inspect)

registry:
  ghcr.io/<owner>/ocserv-ci-runner@sha256:<manifest digest>

runner host:
  docker pull ghcr.io/<owner>/ocserv-ci-runner@sha256:<manifest digest>
  → provisioner uses --pull=never (image must be pre-cached by exact digest)
```

**Refresh SLA:** with `--disableupdate`, the runner image MUST be rebuilt+redeployed
within 30 days of a new GitHub Actions Runner release (GitHub stops scheduling to
old runners ~30 days after a new release). Track actions/runner releases.

The runner host needs NO GitHub runner-management credential. Registry read
access may be public or a minimal read-only token (NOT reused for Actions
registration, publish, deploy, or production).

## Runner host setup (one-time, root, from audited clone — NOT user-writable checkout)

```bash
sudo -i
git clone <repo> /root/ocserv-backport-install && cd /root/ocserv-backport-install
git checkout <verified-sha>
bash scripts/runner-host-install.sh
# Edit /etc/ocserv-ci-runner/provisioner.conf: fill RUNNER_IMAGE (manifest digest from above).
chmod 0600 /etc/ocserv-ci-runner/provisioner.conf   # provisioner main() enforces root:root 0600
iptables -S OCSERV_CI_EGRESS
iptables -S OCSERV_CI_HOST_GUARD
```

**Never** run `sudo scripts/runner-provisioner.sh` from a user-writable checkout —
a non-root user could modify the script that root then executes. Always run the
installed copy at `/usr/local/libexec/ocserv-ci/runner-provisioner`.

## Launch a runner (per cycle)

```bash
# Get a short-lived repository-scoped registration token from a trusted GitHub admin
# terminal. Do NOT store it on the runner host.

sudo -v   # cache sudo creds first (so sudo -n won't consume the token from stdin)
printf '%s\n' "$REGISTRATION_TOKEN" | sudo -n /usr/local/libexec/ocserv-ci/runner-provisioner --registration-token-stdin
unset REGISTRATION_TOKEN
```

The provisioner prints the runner name (CSPRNG-generated, e.g. `ci-build-<ULID>`)
and waits up to `RUNNER_WAIT_TIMEOUT` (default 45m). On timeout it SIGTERM/SIGKILLs
the container (`--rm` removes it); GitHub may leave an offline record (manual cleanup).

## Lockdown verify (while runner runs)

```bash
docker inspect <runner-name> --format '
  Privileged={{.HostConfig.Privileged}}
  ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}}
  User={{.Config.User}}
  OpenStdin={{.Config.OpenStdin}}
  NetworkMode={{.HostConfig.NetworkMode}}
  CapAdd={{.HostConfig.CapAdd}}
  CapDrop={{.HostConfig.CapDrop}}
  Binds={{.HostConfig.Binds}}'
```

Expected: `Privileged=false`, `ReadonlyRootfs=true`, `User=10001:10001`,
`OpenStdin=true` (token via stdin), `NetworkMode=ci-build-egress`,
`CapAdd=[]`, `CapDrop=[ALL]`, `Binds=[]`, no `docker.sock`.

## Firewall + IPv6-absence integration acceptance (RUNNER HOST — ONLY network-isolation acceptance)

```bash
docker network inspect ci-build-egress --format '{{.EnableIPv6}}'   # MUST print false

docker run --rm --network ci-build-egress --entrypoint /bin/sh <image@digest> -ec '
  # IPv6 absence (iproute2 in image)
  ! ip -6 addr show dev eth0 scope global | grep -q .
  ! ip -6 route show default | grep -q .
  # IPv4 egress
  curl -4 -fsS --max-time 5 https://github.com >/dev/null && echo "github v4 OK"
  ! curl -4 -fsS --max-time 5 http://10.20.0.1/ && echo "private denied OK"
  ! curl -4 -fsS --max-time 5 http://169.254.169.254/ && echo "metadata denied OK"
  ! curl -4 -fsS --max-time 5 http://172.30.0.1/ && echo "host-gateway denied OK"
'
iptables -S OCSERV_CI_EGRESS | grep -q br-ci-build-egress
iptables -S OCSERV_CI_HOST_GUARD | grep -q br-ci-build-egress
```

## Image smoke (no token)

```bash
docker run --rm --entrypoint /bin/sh <image@digest> -ec '/opt/actions-runner-src/bin/Runner.Listener --version'
```

## Orphan managed container cleanup (inspect before removing)

```bash
docker ps -aq --filter 'label=com.ocserv-ci.managed-by=runner-provisioner' --filter 'label=com.ocserv-ci.phase=1' \
  | xargs -r docker inspect --format '{{.Name}} state={{.State.Status}} labels={{.Config.Labels}}'
# Review each; if it is a leftover Phase 1 managed container, remove after confirming labels:
#   docker rm -f <id>
# Then GitHub UI → Settings → Actions → Runners → offline → Remove (Phase 1 does NOT auto-clean).
```

## What this runner CANNOT do (by design)

- No Docker socket / sub-containers (cannot run `docker run` inside a job).
- No build toolchain yet (sbuild/dpkg-buildpackage arrive in Phase 3).
- No access to aptly / GPG / R2 / Cloudflare / production SSH.
- No autoscaling; no JIT; no IPv6; one manual launch = one runner = one job, bounded wait.
