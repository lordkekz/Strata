# NixOS module for Strata, running the pre-built container image as a rootless
# Podman container managed by systemd.
#
# Targets the AMD RX 7900 XTX (gfx1100): the default image is the
# `rocm-gfx110x` flavor. See ../docs/DOCKER.md for the image flavors, settings
# and the API.
{
  config,
  lib,
  ...
}:

let
  inherit (lib)
    literalExpression
    mkDefault
    mkEnableOption
    mkForce
    mkIf
    mkOption
    optional
    types
    ;

  cfg = config.services.strata;

  containerName = "strata";
  serviceName = "podman-${containerName}";

  isLoopbackAddress =
    address: builtins.elem address [ "127.0.0.1" "::1" "localhost" "ip6-localhost" ];

  # `podman run -p` wants IPv6 addresses in brackets.
  publishedAddress =
    if lib.hasInfix ":" cfg.bindAddress && !(lib.hasPrefix "[" cfg.bindAddress) then
      "[${cfg.bindAddress}]"
    else
      cfg.bindAddress;

  # Environment variables understood by the image (docs/DOCKER.md, "Settings").
  # The image saves them as the preset `PRESET`; unset ones keep the saved value.
  containerEnvironment =
    {
      PORT = toString cfg.containerPort;
      PRESET = cfg.preset;
      VISION = cfg.vision;
    }
    // lib.optionalAttrs (cfg.family != null) { FAMILY = cfg.family; }
    // lib.optionalAttrs (cfg.model != null) { MODEL = cfg.model; }
    // lib.optionalAttrs (cfg.modelPath != null) { MODEL_PATH = cfg.modelPath; }
    // lib.optionalAttrs (cfg.context != null) { CONTEXT = toString cfg.context; }
    // lib.optionalAttrs (cfg.parallel != null) { PARALLEL = toString cfg.parallel; }
    // lib.optionalAttrs (cfg.kv != null) { KV = cfg.kv; }
    // lib.optionalAttrs (cfg.tune != null) { TUNE = cfg.tune; }
    // lib.optionalAttrs (cfg.gpu != null) { GPU = cfg.gpu; }
    // lib.optionalAttrs (cfg.gpus != null) { GPUS = cfg.gpus; }
    // lib.optionalAttrs (cfg.gpuRoles != null) { GPU_ROLES = cfg.gpuRoles; }
    // lib.optionalAttrs (cfg.strataSet != null) { STRATA_SET = cfg.strataSet; }
    // lib.optionalAttrs cfg.allowDownload { ALLOW_DOWNLOAD = "1"; }
    // lib.optionalAttrs cfg.retune { RETUNE = "1"; }
    // lib.optionalAttrs cfg.tuneAllowSmall { TUNE_ALLOW_SMALL = "1"; }
    // cfg.extraEnvironment;

  # The image's graceful stop (drain, unload, free the GPU memory) needs more
  # time than Podman's default ten seconds; systemd must wait for Podman.
  systemdStopTimeout = if cfg.stopTimeout != null then cfg.stopTimeout + 30 else 150;
in
{
  options.services.strata = {
    enable = mkEnableOption "Strata, a local LLM server, in a rootless Podman container";

    image = mkOption {
      type = types.str;
      default = "ghcr.io/niko1221/strata:0.2.13-rocm-gfx110x";
      example = "ghcr.io/niko1221/strata:latest-rocm-gfx110x";
      description = ''
        Container image to run. The default is the pinned `rocm-gfx110x` flavor
        for the AMD RX 7000 series (gfx1100/gfx1101/gfx1102), including the
        RX 7900 XTX.

        Other flavors from [docs/DOCKER.md](../../docs/DOCKER.md): `cuda13`,
        `cuda12`, `rocm-gfx120x` (RX 9000), `rocm-gfx1151` (Strix Halo) and
        `sycl` (Intel Arc). Pinning a version tag means Strata only updates
        when you change this option (and `pull` lets it through).
      '';
    };

    pull = mkOption {
      type = types.enum [ "always" "missing" "never" "newer" ];
      default = "missing";
      description = ''
        When Podman should look for a newer image (`podman run --pull`).
        `missing` pulls only when the image is not in the local store, so a
        reboot never waits for a registry. `newer` re-checks the tag on every
        start; `always` re-pulls it.
      '';
    };

    autoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Start the container at boot (through its systemd unit).";
    };

    user = mkOption {
      type = types.str;
      default = "strata";
      description = ''
        Account that runs rootless Podman. Rootless mode is what keeps the
        container out of the system's root account; the image itself still runs
        as root *inside* its user namespace.
      '';
    };

    createUser = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Create `user` as a system account (no login shell), with `homeDir` as
        its home, an automatically allocated subuid/subgid range (required by
        rootless Podman) and the `supplementaryGroups` listed below.

        Set to `false` to use an account that already exists. That account then
        needs a subuid/subgid range and membership in `video` and `render`
        itself; this module does not modify it.
      '';
    };

    group = mkOption {
      type = types.str;
      default = if cfg.createUser then cfg.user else "root";
      defaultText = literalExpression ''
        if config.services.strata.createUser then config.services.strata.user else "root"
      '';
      description = "Group that owns `dataDir`.";
    };

    uid = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Static uid for the service account (a free system uid, below 1000).
        Only needed with `sdnotify = "healthy"`, whose user-manager dependency
        requires a fixed uid; otherwise the uid is allocated automatically.
      '';
    };

    supplementaryGroups = mkOption {
      type = types.listOf types.str;
      default = [ "video" "render" ];
      description = ''
        Host groups added to the service account (when `createUser` is true).
        They are needed to open `/dev/kfd` and `/dev/dri/renderD*`, which the
        image's user namespace cannot access through the device files'
        ownership alone. `--group-add=keep-groups` (see `keepGroups`) passes
        them into the container.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/strata/data";
      description = ''
        Host directory mounted at `/data`: model files, the prepared pack,
        presets, tuning results, logs and the API key. It needs room for the
        model (tens of GB; see [docs/MODELS.md](../../docs/MODELS.md)). Point it
        at a big disk if the root filesystem is small.
      '';
    };

    homeDir = mkOption {
      type = types.str;
      default = "/var/lib/strata/home";
      description = ''
        Home directory of the service account when `createUser` is true.
        Rootless Podman keeps its image and container storage below it (about
        2.4 GB for the `rocm-gfx110x` image), outside the mounted model data.
      '';
    };

    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Host address the API is published on. The default keeps Strata on this
        computer. Set `0.0.0.0` (or a LAN address) to let other machines
        connect, and use a long key in `environmentFile`.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = ''
        Host port the API is published on. Rootless Podman cannot bind ports
        below 1024 unless `net.ipv4.ip_unprivileged_port_start` is lowered on
        the host.
      '';
    };

    containerPort = mkOption {
      type = types.port;
      default = 8080;
      description = "Port the server listens on inside the container (`PORT`).";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open `port` in the host firewall, but only when `bindAddress` is not a
        loopback address. The default therefore changes nothing for a
        local-only setup and is enough once `bindAddress = "0.0.0.0"` is set.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/strata.env";
      description = ''
        File passed to the container with `podman run --env-file`: `KEY=value`
        lines, normally just
        `API_KEY=<openssl rand -hex 24>`.

        The file is read as the service account, so a secret manager must make
        it readable by that account (for example `owner = "strata"` in
        sops-nix). It can also carry any other image variable from
        [docs/DOCKER.md](../../docs/DOCKER.md#settings); the typed options below
        take precedence over it.

        Without this, the image generates a key on first start, keeps it in
        `dataDir` and logs how to show it:
        `podman exec strata strata launch --show-key --preset docker`.
      '';
    };

    family = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "qwen";
      description = ''
        Model family (`FAMILY`): `qwen` (ISTA-DASLab originals), `unsloth`,
        `gyro`, `coder`, `swift`, ... Unset lets Strata choose and say so in the
        log.
      '';
    };

    model = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "IQ3_XXS";
      description = ''
        Model size (`MODEL`), such as `IQ2_XS`, `IQ3_XXS`, `Q2_0` or
        `UD-Q4_K_XL`. Unset lets Strata choose what suits the card.
      '';
    };

    modelPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/models";
      description = ''
        GGUF files you already have, as a path *inside the container*
        (`MODEL_PATH`). Mount the folder with `extraVolumes`, for example
        `extraVolumes = [ "/srv/gguf/IQ3_XXS:/models:ro" ];`.
      '';
    };

    context = mkOption {
      type = types.nullOr (types.either types.int types.str);
      default = null;
      example = "32k";
      description = "Context size (`CONTEXT`): `32k`, `64k`, `128k`, `256k` or a number. Unset uses the largest that fits.";
    };

    parallel = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Requests answered at the same time (`PARALLEL`, 1 to 8). Unset fits it to the card.";
    };

    vision = mkOption {
      type = types.enum [ "off" "on" "gpu" "cpu" ];
      default = "off";
      description = "Picture support (`VISION`). The picture-reader file is downloaded with the model when not `off`.";
    };

    kv = mkOption {
      type = types.nullOr (types.enum [ "int8" "q4_0" "k8v4" "fp16" ]);
      default = null;
      description = "Conversation-memory format (`KV`). Unset uses the image's default, `int8`.";
    };

    tune = mkOption {
      type = types.nullOr (types.enum [ "skip" "quick" "thorough" ]);
      default = null;
      description = ''
        Tuning (`TUNE`), done once and kept in the preset. Unset uses the
        image's default, `skip`; a first boot with `quick` takes longer but
        fits the run settings to this computer.
      '';
    };

    retune = mkOption {
      type = types.bool;
      default = false;
      description = "Tune again although a tuning result is saved (`RETUNE=1`).";
    };

    tuneAllowSmall = mkOption {
      type = types.bool;
      default = false;
      description = "Allow tuning on a small card (`TUNE_ALLOW_SMALL=1`).";
    };

    gpu = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0";
      description = "Graphics card numbers (`GPU`), as the monitor lists them. Unset uses all cards that fit.";
    };

    gpus = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0,1";
      description = "Several graphics cards (`GPUS`). Not together with `gpuRoles`.";
    };

    gpuRoles = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "1=main,0=helper";
      description = "A role per card (`GPU_ROLES`). Not together with `gpu`/`gpus`.";
    };

    allowDownload = mkOption {
      type = types.bool;
      default = false;
      description = "Download the model even though model files of the older layout were left unread in `/data/models` (`ALLOW_DOWNLOAD=1`).";
    };

    preset = mkOption {
      type = types.str;
      default = "docker";
      description = "Preset name in `/data` (`PRESET`).";
    };

    strataSet = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "prefill=65536 STRATA_PIN_BY_NEED=1";
      description = "Advanced engine settings, space separated, as for `strata launch --set` (`STRATA_SET`).";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { STRATA_PIN_BY_NEED = "1"; };
      description = ''
        Extra container environment variables. They are merged last, so they
        can override the typed options above and the image defaults.
      '';
    };

    gpuDevices = mkOption {
      type = types.listOf types.str;
      default = [
        "/dev/kfd:/dev/kfd"
        "/dev/dri:/dev/dri"
      ];
      description = "Devices passed to the container. AMD needs `kfd` and `dri`.";
    };

    keepGroups = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Pass `--group-add=keep-groups` to Podman. Rootless Podman maps the
        container's root to the service account, and this flag hands that
        process the account's `video` and `render` groups, which it needs for
        `/dev/kfd` and `/dev/dri`. Only turn it off if you pass your own group
        mapping in `extraOptions`.
      '';
    };

    memlock = mkOption {
      type = types.nullOr types.str;
      default = "-1:-1";
      description = ''
        `--ulimit memlock` for the container. The engine pins the RAM it uses
        for the model, so the default is unlimited in both directions; the unit
        raises the service account's hard limit to match. Set to `null` to omit
        the flag (the engine will not be able to pin memory).
      '';
    };

    shmSize = mkOption {
      type = types.nullOr types.str;
      default = "2g";
      description = "Size of `/dev/shm` in the container (`--shm-size`). `null` omits the flag.";
    };

    stopTimeout = mkOption {
      type = types.nullOr types.int;
      default = 120;
      description = ''
        Seconds the container gets to drain and unload the model
        (`podman run --stop-timeout`). systemd waits 30 seconds longer than this
        before killing Podman. The image needs about two minutes for a big
        model; Podman's ten-second default would kill it with exit code 137.
      '';
    };

    sdnotify = mkOption {
      type = types.enum [ "conmon" "healthy" "container" ];
      default = "conmon";
      description = ''
        How Podman signals readiness to systemd. `conmon` marks the unit active
        when the container starts (the image's healthcheck still reports
        starting/healthy through `podman ps`). `healthy` waits for the
        healthcheck, which means the first start blocks until the model has
        downloaded and loaded (minutes to hours); it also needs a static uid
        (`services.strata.uid`), because the container then depends on that
        account's user manager.
      '';
    };

    extraVolumes = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/srv/gguf/IQ3_XXS:/models:ro" ];
      description = "Additional `podman run -v` arguments. `dataDir:/data` is always mounted.";
    };

    extraDevices = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional `podman run --device` arguments.";
    };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--security-opt=seccomp=unconfined" ];
      description = "Additional `podman run` options, appended last.";
    };

    extraServiceConfig = mkOption {
      type = types.attrs;
      default = { };
      description = ''
        Extra systemd `serviceConfig` settings for `podman-strata.service`.
        Use with care: this module already raises `LimitMEMLOCK` and
        `TimeoutStopSec` for the engine.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.virtualisation.oci-containers.backend == "podman";
        message = ''
          services.strata runs the container as rootless Podman, so
          virtualisation.oci-containers.backend must be "podman".
        '';
      }
      {
        assertion = cfg.createUser
          || config.users.users.${cfg.user}.isSystemUser
          || config.users.users.${cfg.user}.isNormalUser;
        message = ''
          services.strata.user = "${cfg.user}" is not a defined account.
          Set services.strata.createUser = true, or define the account
          (users.users.${cfg.user}) and set createUser = false.
        '';
      }
      {
        assertion = builtins.hasAttr cfg.group config.users.groups;
        message = ''
          services.strata.group = "${cfg.group}" is not a defined group.
          Leave createUser = true, or set services.strata.group to an existing
          group.
        '';
      }
      {
        assertion = !(lib.hasInfix ":" cfg.dataDir);
        message = "services.strata.dataDir must not contain ':' (it becomes the source of a Podman volume mount).";
      }
      {
        assertion = cfg.gpu == null || cfg.gpuRoles == null;
        message = "services.strata.gpu and services.strata.gpuRoles cannot be set together (GPU vs GPU_ROLES).";
      }
      {
        assertion = cfg.gpus == null || cfg.gpuRoles == null;
        message = "services.strata.gpus and services.strata.gpuRoles cannot be set together (GPUS vs GPU_ROLES).";
      }
      {
        assertion = cfg.parallel == null || (cfg.parallel >= 1 && cfg.parallel <= 8);
        message = "services.strata.parallel must be between 1 and 8 (PARALLEL).";
      }
    ];

    warnings = lib.optionals (!cfg.createUser) [
      ''
        services.strata.createUser = false: make sure "${cfg.user}" has a
        subuid/subgid range (users.users.${cfg.user}.autoSubUidGidRange = true)
        and is in these groups: ${lib.concatStringsSep ", " cfg.supplementaryGroups}.
      ''
    ] ++ lib.optionals (cfg.environmentFile == null && !(isLoopbackAddress cfg.bindAddress)) [
      ''
        services.strata is published on ${cfg.bindAddress} without an
        environmentFile. The image generates an API key into
        ${cfg.dataDir}/state; clients need it. Set services.strata.environmentFile
        to a file containing API_KEY=... next to a long key.
      ''
    ] ++ lib.optionals (cfg.port < 1024) [
      ''
        services.strata.port is ${toString cfg.port}, below 1024. Rootless
        Podman cannot publish it unless the host lowers
        net.ipv4.ip_unprivileged_port_start.
      ''
    ];

    # Rootless Podman: the module wires the unit to `user`, gives it the
    # delegated cgroup it needs and keeps the image store below homeDir.
    virtualisation.podman.enable = mkDefault true;
    virtualisation.oci-containers.backend = mkDefault "podman";

    users.users.${cfg.user} = lib.mkMerge [
      (mkIf cfg.createUser {
        isSystemUser = true;
        inherit (cfg) uid;
        group = cfg.user;
        home = cfg.homeDir;
        createHome = true;
        # Rootless Podman maps a range of host ids into the container; the range
        # must be allocated for this account.
        autoSubUidGidRange = true;
        extraGroups = cfg.supplementaryGroups;
        description = "Strata server (rootless Podman)";
      })
      # virtualisation.oci-containers reads this as a Boolean, so it must not
      # stay at its `null` default for a non-root podman user; linger also gives
      # the account a user manager, which is Podman's recommended setup.
      { linger = mkDefault true; }
    ];

    users.groups.${cfg.user} = mkIf cfg.createUser { };

    systemd.tmpfiles.rules =
      [
        "d ${cfg.dataDir} 0700 ${cfg.user} ${cfg.group} -"
      ]
      ++ optional cfg.createUser "d ${cfg.homeDir} 0700 ${cfg.user} ${cfg.group} -";

    virtualisation.oci-containers.containers.${containerName} = {
      inherit (cfg)
        image
        pull
        autoStart
        ;

      environment = containerEnvironment;
      environmentFiles = optional (cfg.environmentFile != null) cfg.environmentFile;

      ports = [
        "${publishedAddress}:${toString cfg.port}:${toString cfg.containerPort}"
      ];

      volumes = [
        "${cfg.dataDir}:/data"
      ] ++ cfg.extraVolumes;

      devices = cfg.gpuDevices ++ cfg.extraDevices;

      extraOptions =
        optional cfg.keepGroups "--group-add=keep-groups"
        ++ optional (cfg.memlock != null) "--ulimit=memlock=${cfg.memlock}"
        ++ optional (cfg.shmSize != null) "--shm-size=${cfg.shmSize}"
        ++ optional (cfg.stopTimeout != null) "--stop-timeout=${toString cfg.stopTimeout}"
        ++ cfg.extraOptions;

      podman = {
        inherit (cfg) sdnotify;
        user = cfg.user;
      };
    };

    systemd.services.${serviceName} = {
      description = "Strata local LLM server (rootless Podman)";

      # A bind mount can live on another filesystem; wait for its mount.
      # (mkForce replaces the oci-containers default, which points at
      # /run/user/<uid> and assumes a login session.)
      unitConfig.RequiresMountsFor = mkForce (
        [ cfg.dataDir ] ++ optional cfg.createUser cfg.homeDir
      );

      # Podman's rootless state lives in the runtime directory; systemd owns it
      # (RuntimeDirectory is set by the oci-containers module) and this module
      # keeps it private.
      environment.XDG_RUNTIME_DIR = "/run/${containerName}";

      serviceConfig = {
        # The service account may pin the model's RAM only if its hard limit is
        # unlimited; a system unit may raise it before dropping privileges.
        LimitMEMLOCK = "infinity";

        # Podman gets stopTimeout seconds to stop the container gracefully.
        TimeoutStopSec = mkForce systemdStopTimeout;

        RuntimeDirectoryMode = "0700";
        RestartSec = 10;
      } // cfg.extraServiceConfig;
    };

    networking.firewall.allowedTCPPorts = mkIf (
      cfg.openFirewall && !(isLoopbackAddress cfg.bindAddress)
    ) [ cfg.port ];
  };
}
