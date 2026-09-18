{ pkgs, ... }:

{

  time.timeZone = "Pacific/Honolulu";
  i18n.defaultLocale = "en_US.UTF-8";

  # niri compositor
  programs.niri.enable = true;

  # noctalia shell (package + recommended services: NetworkManager, BT, UPower, power profiles)
  programs.noctalia = {
    enable = true;
    recommendedServices.enable = true;
    systemd.enable = true;
  };

  # greetd with niri session
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd niri-session";
        user = "greeter";
      };
    };
  };

  environment.systemPackages = with pkgs; [
    git
    wget
    curl
    foot
    xwayland-satellite
    papirus-icon-theme

    # terminal tools
    fish
    fzf
    yazi
    gh
    fastfetch
    starship
    neovim

    # runtime for pi.dev / oh-my-pi (omp) coding agents
    bun
    nodejs
  ];

  programs.fish.enable = true;
  users.defaultUserShell = pkgs.fish;
}