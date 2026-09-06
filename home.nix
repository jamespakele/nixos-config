{ config, pkgs, ... }: {
  home.username = "pakele";
  home.homeDirectory = "/home/pakele";
  home.stateVersion = "26.05";

  home.packages = with pkgs; [
    nodejs_22 # pi engine requirement: Node >= 22.19
    bun       # omp's recommended runtime
    git
    tmux      # agent sessions survive TTY logout
  ];

  # Let `pi install npm:...` / npm -g work without sudo, declaratively
  home.sessionVariables.NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
  home.sessionPath = [ "${config.home.homeDirectory}/.npm-global/bin" ];

  programs.git.enable = true;
  programs.bash.enable = true;
}