# Strata on NixOS (rootless Podman)

`nixos-module.nix` runs the pre-built Strata container image as a rootless
Podman container under systemd. It is set up for an **AMD RX 7900 XTX**
(gfx1100): the default image is the `rocm-gfx110x` flavor from
[docs/DOCKER.md](../../docs/DOCKER.md), the API is published on
`127.0.0.1:8080`, and model data lives in `/var/lib/strata/data`.

The module does not need ROCm on the host: the userspace is in the image. The
host needs the `amdgpu` kernel driver (any current NixOS kernel has it) and the
`video`/`render` groups, which NixOS provides.

Validation so far: the module evaluates against NixOS (nixpkgs unstable) and
the resulting unit and container arguments were checked. It has not been run on
a 7900 XTX from this checkout.

## Usage

With the flake:

```nix
{
  inputs.strata.url = "github:lordkekz/Strata";

  outputs = { self, nixpkgs, strata, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        strata.nixosModules.default
        ./hardware-configuration.nix
        {
          services.strata.enable = true;
          # Provisioned by sops-nix or agenix, not written by hand.
          services.strata.environmentFile = "/run/secrets/strata.env";
        }
      ];
    };
  };
}
```

Or copy `nixos-module.nix` into your configuration and `imports = [ ./nixos-module.nix ];`.
A complete minimal example is in [example.nix](example.nix).

`services.strata` enables `virtualisation.podman` and the `podman` backend of
`virtualisation.oci-containers`, creates a `strata` system account (home
`/var/lib/strata/home`, automatic subuid/subgid range, groups `video` and
`render`, lingering enabled) and adds `podman-strata.service`.

## The API key

The image always requires a key and refuses to serve without one. There are
two supported ways to provide it.

Leave `environmentFile` unset and let the image create the key on first start.
It is kept in `dataDir` and the log says how to show it:

```sh
sudo -u strata env HOME=/var/lib/strata/home XDG_RUNTIME_DIR=/run/strata \
  podman exec strata strata launch --show-key --preset docker
```

To use a key of your own, provision it with a secret manager and point
`environmentFile` at the generated file. With sops-nix:

```nix
sops.secrets."strata/env".owner = "strata";
services.strata.environmentFile = config.sops.secrets."strata/env".path;
```

The secret holds `KEY=value` lines, normally one line (`API_KEY=...`). It is
read as the service account, so make it readable by `strata` (`owner` above).
It may also carry any other image variable from
[docs/DOCKER.md](../../docs/DOCKER.md#settings); the typed `services.strata`
options are applied after it and win.

Do not create the file by hand: a path under `/run` is memory-backed, so the
file disappears on reboot and the unit fails to start.

## Settings

All options have descriptions in
[nixos-module.nix](nixos-module.nix). The frequently used ones:

| Option | Default | Meaning |
| --- | --- | --- |
| `image` | `ghcr.io/niko1221/strata:0.2.13-rocm-gfx110x` | Pinned image tag. The docs' examples use `0.2.7`; `0.2.13` is the newest published `gfx110x` tag. |
| `pull` | `missing` | `always` / `missing` / `never` / `newer` (`podman run --pull`). |
| `dataDir` | `/var/lib/strata/data` | Mounted at `/data`: models, packs, presets, tuning, logs, key. |
| `bindAddress`, `port` | `127.0.0.1`, `8080` | Published API address. `openFirewall` (default `true`) opens `port` only when `bindAddress` is not loopback. |
| `environmentFile` | `null` | `API_KEY=...` file, see above. |
| `family`, `model` | `null` | `FAMILY` / `MODEL`; unset lets Strata choose what fits the card. |
| `context`, `parallel`, `vision`, `kv`, `tune` | unset / `vision = "off"` | The corresponding image variables. |
| `gpu`, `gpus`, `gpuRoles` | `null` | Card selection; `gpu`/`gpus` cannot be combined with `gpuRoles`. |
| `modelPath`, `extraVolumes` | `null`, `[]` | Use GGUF files you already have: `modelPath = "/models"; extraVolumes = [ "/srv/gguf/IQ3_XXS:/models:ro" ];`. |
| `user`, `createUser`, `group` | `strata`, `true`, `strata` | Rootless Podman account and owner of `dataDir`. |
| `uid` | `null` | Static uid for that account; only needed with `sdnotify = "healthy"`. |
| `supplementaryGroups` | `[ "video" "render" ]` | Host groups for the account (needed for `/dev/kfd` and `/dev/dri`). |
| `keepGroups` | `true` | Passes `--group-add=keep-groups`, which is how the root-mapped container process gets those groups. |
| `memlock`, `shmSize`, `stopTimeout` | `-1:-1`, `2g`, `120` | The flags DOCKER.md asks for; the unit raises `LimitMEMLOCK` to unlimited and waits longer than `stopTimeout` on stop. |
| `sdnotify` | `conmon` | `healthy` makes `systemctl start` wait for the model to be served. |
| `extraEnvironment`, `extraOptions`, `extraServiceConfig` | `{}`, `[]`, `{}` | Escape hatches. |

Model sizes for a 24 GB card: Qwen3.8 IQ3_XXS needs about 47 GB of RAM + VRAM in
total, Q2_0 about 37.6 GB, and the Coder pack about 32 GB; see
[docs/MODELS.md](../../docs/MODELS.md). A 7900 XTX together with 64 GB of RAM
runs all of them.

## Operating it

```sh
systemctl status podman-strata            # the unit (container starts at boot)
journalctl -u podman-strata -f            # what it is doing; the first start downloads the model

# Rootless Podman keeps its state in the strata account, so plain `sudo podman`
# does not see the container. Use the account (or its environment):
sudo -u strata env HOME=/var/lib/strata/home XDG_RUNTIME_DIR=/run/strata podman ps
sudo -u strata env HOME=/var/lib/strata/home XDG_RUNTIME_DIR=/run/strata podman logs -f strata
sudo -u strata env HOME=/var/lib/strata/home XDG_RUNTIME_DIR=/run/strata podman exec strata strata monitor
sudo -u strata env HOME=/var/lib/strata/home XDG_RUNTIME_DIR=/run/strata podman exec strata strata monitor --once
```

`podman ps` shows `healthy` once the model is downloaded and served; the first
start can take hours. `systemctl start` returns as soon as the container is
running (`sdnotify = "conmon"`), not when the model is ready.

For coding apps on this computer:

- OpenAI-compatible base URL `http://127.0.0.1:8080/v1`
- Anthropic-compatible base URL `http://127.0.0.1:8080`
- key = the one in `environmentFile`; model name from `GET /v1/models`

Stopping the service drains requests, unloads the model and frees the GPU
memory: the unit gives the container `stopTimeout` seconds (120 by default) and
waits 30 seconds longer before systemd kills Podman. Starting again reuses the
model, pack and preset in `dataDir`.

## Updating

Change `services.strata.image` to a newer tag and run `nixos-rebuild switch`.
The unit removes the old container first and `pull = "missing"` fetches the new
image. Use `pull = "newer"` (or `"always"`) to track a moving tag such as
`latest-rocm-gfx110x` on every start.

Models, the prepared pack, presets and tuning results stay in `dataDir`. After
an engine update, a tuning result can be stale; set `retune = true` once (or
`tune = "quick"`).

## Rootless notes and troubleshooting

- **Why rootless?** The module runs `podman` as the unprivileged `strata`
  account. The image still runs as root inside its own user namespace; `/data`
  files are owned by `strata` on the host.
- **`Permission denied` on `/dev/kfd` or `/dev/dri`.** `createUser = true`
  puts `strata` in `video` and `render` and `keepGroups = true` passes those
  groups on. If you use `createUser = false`, add both groups and a
  subuid/subgid range to that account yourself; the module still enables
  lingering for it and gives the unit its own private runtime directory.
  `ls -l /dev/kfd /dev/dri/renderD*` shows the host's permissions.
- **`cannot set RLIMIT_MEMLOCK` / the engine cannot pin memory.** The unit sets
  `LimitMEMLOCK = "infinity"`; keep `memlock = "-1:-1"`. If you override
  `extraServiceConfig`, do not drop `LimitMEMLOCK`.
- **Podman starts but cannot find its state** (`XDG_RUNTIME_DIR`). The unit sets
  `XDG_RUNTIME_DIR=/run/strata` and keeps that runtime directory private;
  preserve both when using `extraServiceConfig` or your own unit.
- **First start seems stuck.** It is downloading/preparing tens of GB. Follow
  `journalctl -u podman-strata -f`; an interrupted download continues where it
  stopped. The image's healthcheck has a two-hour start period.
- **Exit code 137 on stop.** Something killed Podman early: keep
  `stopTimeout = 120` (or more) and do not lower the unit's `TimeoutStopSec`
  below it.
- **Wrong flavor message.** The image says it does not match the card: use
  `rocm-gfx110x` for RX 7000 (gfx1100/1101/1102), `rocm-gfx120x` for RX 9000,
  `cuda13`/`cuda12` for NVIDIA, `sycl` for Intel Arc.
- **A port below 1024.** Rootless Podman cannot publish it; choose a port above
  1023 or lower `net.ipv4.ip_unprivileged_port_start` on the host.
- **Disk use.** The image and its layers live in `/var/lib/strata/home`
  (about 2.4 GB for `rocm-gfx110x`); the model and pack live in `dataDir`.
  Both stay across reboots and updates.
