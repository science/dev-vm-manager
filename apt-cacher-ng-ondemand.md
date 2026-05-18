# Move apt-cacher-ng to on-demand (driven by VM rebuilds)

Brief for a fresh session. apt-cacher-ng (acng) is currently always-on
on the host (linux-bambam) and has become a recurring source of
breakage. The motivating use case — rebuilding multiple Incus dev VMs
without redownloading 1 GB+ of packages — is real but bursty. The
proposal is to leave acng installed but disabled by default, and have
this project's VM-rebuild flow flip it on/off around the rebuild.

## The problem (concrete)

Current state on linux-bambam:

- `apt-cacher-ng.service` is always running, listening on `0.0.0.0:3142`
- `/etc/apt/apt.conf.d/01acng` routes **all** apt traffic on the host
  through it (`Acquire::http::Proxy "http://127.0.0.1:3142";`)
- Dev VMs (dev-1, dev-2) are also configured to use the host's acng
  (set up by `create-dev-vm`)

Observed failure pattern:

- `/var/log/apt-cacher-ng/apt-cacher.log`: **2034 error lines**, **100%
  HTTP 503**, since the log started 2026-03-12 (~54 days)
- Bursts cluster around **08–11 AM** most days, which lines up with
  `apt-daily.timer` firing. Once acng gets into a bad state during the
  cron run, every subsequent apt operation on the host returns 503
  until acng is restarted.
- `sudo systemctl restart apt-cacher-ng` clears the bad state every
  time. So this is **acng getting stuck internally** (likely connection
  pool / worker after an upstream stall), not the upstream archive.
- The acng error message body is `503 No such process`, which is
  ESRCH from `strerror()` — consistent with acng failing to find a
  live worker for the request.

Recent example (today, while installing CoolerControl): direct
`curl http://archive.ubuntu.com/ubuntu/dists/noble/InRelease` returned
200, same URL via `curl -x http://127.0.0.1:3142` returned 503. After
`systemctl restart apt-cacher-ng`, both worked.

## Wider impact: the HTTPS-bypass tax

acng can't MITM TLS, so every new HTTPS apt repo has to either:

1. Bypass the proxy: drop a file in `/etc/apt/apt.conf.d/` with
   `Acquire::https::Proxy::<host> "DIRECT";`, or
2. Be added to `PassThroughPattern` in
   `/etc/apt-cacher-ng/zz_passthrough.conf` (CONNECT tunnel, no
   caching).

Existing files showing this tax:
- `/etc/apt/apt.conf.d/02docker-proxy` — `download.docker.com`
- `/etc/apt/apt.conf.d/03nvidia-proxy` — `nvidia.github.io`
- `/etc/apt/apt.conf.d/04coolercontrol-proxy` — `dl.cloudsmith.io`
  (added today during CoolerControl install)
- `zz_passthrough.conf` — hashicorp, google, esm.ubuntu.com,
  packagecloud, mozilla, launchpad, mullvad, zettlr, cloudfront

Every new HTTPS repo costs a new bypass config. Removing acng from the
default path eliminates this tax going forward.

## Proposal: on-demand mode

Keep the package installed. Disable the service. Decouple apt config
from acng presence. Have `create-dev-vm` (and any future bulk-VM
operation here) flip acng on for the duration of the rebuild and off
afterward. Net effect: acng is up only when it's actually paying for
itself.

Sketch:

```
~/.local/bin/acng-mode {on|off|status}
  on:  systemctl start apt-cacher-ng
       symlink/copy /etc/apt/apt.conf.d/01acng into place
  off: rm /etc/apt/apt.conf.d/01acng
       systemctl stop apt-cacher-ng
  status: print which side it's on
```

`create-dev-vm` would wrap its work in `acng-mode on` … `acng-mode off`,
with an `EXIT` trap so a failed rebuild still restores the off state.

## Decisions to make before implementing

1. **VM apt config when host acng is off.** Currently dev VMs route
   apt through the host's acng (see `provision.sh` /
   `create-dev-vm`). Options:
     a. VMs use acng only during the rebuild window, fall back to
        direct upstream the rest of the time. Means VM-side apt config
        also needs flipping (more moving parts, but matches host).
     b. VMs always use the host's acng. When host acng is off, VM apt
        breaks. Acceptable if VMs are short-lived and only used for
        rebuild-and-test.
     c. Host runs acng on a different port/hostname only the VMs see
        (e.g. bound to the bridge), so VMs always have it but the
        host's apt path doesn't go through it. Decouples the two
        problems. Preferred if both host and VMs need flexibility.

2. **Existing HTTPS-bypass files.** When acng is off, the `01acng` file
   isn't loaded so the bypass files are inert and harmless. Leave them?
   Or remove? Recommend leaving — they cost nothing when acng is off
   and remove the need to recreate them when acng is on.

3. **Should the off-mode also stop the cron-driven 503 storms?** Yes,
   automatically — if `01acng` isn't installed, `apt-daily.timer` will
   talk direct upstream and never touch acng. Confirm this is desired
   (it is — that's the whole point).

4. **Failsafe.** What if `acng-mode on` is flipped but the rebuild
   crashes before `acng-mode off`? Need an `EXIT` trap in
   `create-dev-vm`. Also worth a `systemd` timer that asserts
   off-mode at e.g. 03:00 nightly, in case a trap is missed.

## Touchpoints

- `~/.config/yadm/bootstrap` — currently installs acng + writes
  `01acng` for host machines (`is_host_machine` block near line 30).
  Needs to stop installing `01acng` by default. Keep the package
  install; remove the unconditional apt-config wiring.
- `~/.config/yadm/CLAUDE.md` (the linux-bambam one at `~/CLAUDE.md`)
  — has a section explaining the HTTPS bypass / PassThroughPattern
  setup. Update or replace once on-demand lands.
- `~/dev/dev-vm-manager/create-dev-vm` and `provision.sh` —
  add `acng-mode on/off` wrapping plus VM-side handling per
  decision (1).
- `~/dev/dev-vm-manager/install.sh` — install `acng-mode` script
  symlink under `~/.local/bin/` alongside `boot-vm` etc.
- `~/.config/yadm/test-dotfiles.sh` — current tests probably assume
  acng is enabled. Update so they accept either state, or check that
  on-demand is correctly wired (e.g. `01acng` absent when service is
  inactive).

## Quick tests during implementation

- Toggle the script, confirm `apt update` works in both states (uses
  proxy when on, direct when off).
- Run `create-dev-vm dev-1` end-to-end with the wrap in place;
  verify `acng-mode status` is `off` after.
- Force a failure mid-rebuild (`Ctrl-C`), confirm trap restores off
  state.
- Confirm the daily 503 burst stops after a few days (check
  `/var/log/apt-cacher-ng/apt-cacher.log` no longer accumulates errors
  outside of explicit on-windows).

## Out of scope here

- Why acng's connection pool gets stuck. Not worth investigating if
  the new architecture only runs it for short, bounded windows
  initiated by a script. If 503s start showing up inside on-windows
  (i.e. during VM rebuilds), revisit then.
- Replacing acng with something else (squid-deb-proxy,
  squid+ssl-bump, a flat HTTP cache). Possible future move; not
  needed for the on-demand pivot.
