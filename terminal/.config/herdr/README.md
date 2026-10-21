# herdr notes

Agent priority (ranks, alt+g, the picker, snooze) moved to its own plugin,
[Mindful-Stack/herdr-agent-priority](https://github.com/Mindful-Stack/herdr-agent-priority),
checked out and linked from `~/Source/herdr-agent-priority` (`herdr plugin link`).
Its state is in `~/.local/state/herdr/plugins/agent-priority/`; its keys are the
five `plugin_action` bindings in `config.toml`.

## herdr behaviour worth knowing

Four things that cost real time to find, all verified on 0.8.x:

- **`herdr agent focus` does not move the client.** `agent.focus` is not in the
  server's client-shell method allowlist, so it updates server state and the
  attached client overwrites it a second later. It reads back correct
  immediately, which is what makes it so convincing. `workspace.focus` and
  `tab.focus` *are* routed to the client, so the three together are what
  actually move the view.
- **Metadata tokens do not survive a restart.** Session restore rebuilds them
  empty, which is why the ranks live in a file and the plugin re-stamps them
  from a startup hook.
- **`herdr notification show` does nothing under foot.** It reports
  `{"shown": true}` regardless. Its terminal backend only recognises ghostty,
  iTerm, kitty and wezterm. `notify-send` talks to whatever owns the
  notification bus, which under Omarchy 4 is quickshell. The same flaw means
  `[ui.toast] delivery = "system"` has been dead since the move to foot.
- **Focusing from inside a popup does not stick.** The call succeeds and the
  session restores the previous focus as the popup closes. Hence the split
  between `pick`, which runs in the popup and writes its choice to a file, and
  `open`, which runs from the keybind and does the focusing afterwards.

And one trap that is not herdr's fault: a client and server running *different
builds of the same version string* behave strangely with no warning. Compare
`/proc/<pid>/exe` against the binary on disk.
