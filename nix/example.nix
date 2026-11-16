# Minimal NixOS configuration for Strata on an AMD RX 7900 XTX (gfx1100).
#
# Import the module through the flake (inputs.strata.nixosModules.default) or
# copy it next to this file and import it directly:
#
#   imports = [ ./nixos-module.nix ];
#
{ ... }:

{
  services.strata = {
    enable = true;

    # Optional: put the API key in a file instead of letting the image create
    # one in the data directory. The file contains KEY=value lines and must be
    # readable by the `strata` service account, for example:
    #
    #   API_KEY=<openssl rand -hex 24>
    #
    # With sops-nix:
    #
    #   sops.secrets."strata/env".owner = "strata";
    #   services.strata.environmentFile = config.sops.secrets."strata/env".path;
    #
    environmentFile = null;

    # The defaults are what a 7900 XTX wants:
    #   image = "ghcr.io/niko1221/strata:0.2.13-rocm-gfx110x"
    #   dataDir = "/var/lib/strata/data"   (mounted at /data)
    #   bindAddress = "127.0.0.1"; port = 8080
    #   VISION = off, model chosen by Strata, context as large as fits
    #
    # Examples:
    # family = "qwen";
    # model = "IQ3_XXS";          # needs ~47 GB of RAM + VRAM in total
    # context = "32k";
    # tune = "quick";             # one-time tuning, kept in the preset
    #
    # Let other computers use it (openFirewall then applies automatically):
    # bindAddress = "0.0.0.0";
  };

  # The module enables rootless Podman and creates the `strata` system account.
  # Nothing else is required on the host besides the amdgpu kernel driver.
}
