# dotfiles

Configs for the Omarchy (Arch/Hyprland) laptop, managed with GNU stow.

## Fresh install

```sh
git clone <this-repo> ~/dotfiles
cd ~/dotfiles

# 1. Stow the home-directory packages (NOT system/ — it is not a stow package)
stow -t ~ shell system-ui terminal tools

# 2. System-level config outside $HOME (logind lid/hibernate behavior, ...)
./system/install.sh

# 3. Enable the persistent tmux server (unit file comes from the terminal
#    package, but the enable-symlink lives outside the repo)
systemctl --user daemon-reload
systemctl --user enable --now tmux.service
```

## Layout

| Directory   | What                                             | How it applies            |
|-------------|--------------------------------------------------|---------------------------|
| `shell`     | shell rc files                                   | `stow -t ~ shell`         |
| `system-ui` | Hyprland, waybar, desktop                        | `stow -t ~ system-ui`     |
| `terminal`  | terminal emulators, tmux (+ tmux.service unit)   | `stow -t ~ terminal`      |
| `tools`     | misc app configs                                 | `stow -t ~ tools`         |
| `system`    | files under `/etc` — mirror tree, copied not linked | `./system/install.sh`  |

## Notes

- **Never run `stow */`** — that would stow `system/` into `$HOME` and create
  a stray `~/etc`. Stow the four home packages by name.
- The tmux server runs as a systemd user service so it survives compositor /
  logind crashes; sessions auto-save every 10 min (tmux-continuum) and restore
  on server start. Attach with `tmux attach`, never bare `tmux` (that creates
  an extra session, or worse, a session-bound server if the service is down).
- After changing anything in `system/etc/`, re-run `./system/install.sh`.
  logind config applies at next boot — do **not** restart systemd-logind from
  inside a session (it kills Hyprland and everything in it).
