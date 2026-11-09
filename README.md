# PIA VPN for Noctalia

Connect to Private Internet Access from your Noctalia v5 shell. Sign in with
your PIA account, pick a location, and see at a glance whether your traffic is
protected.

| Field | Value |
| --- | --- |
| ID | `lmaule/pia-vpn` |
| Entries | Bar widget `widget` · panel `panel` · control-centre tile `shortcut` · service `status` |
| Requires | Noctalia ≥ 5.4 (plugin API 43), the official PIA client (`piactl`) |

## Requirements

The plugin drives the official PIA client's daemon through `piactl`, so the
tunnel, kill switch and DNS handling are PIA's own.

```sh
yay -S piavpn-bin
sudo systemctl enable --now piavpn.service
```

## Install

```sh
mkdir -p ~/.local/share/noctalia/plugins
git clone https://github.com/lmaule/noctalia-pia-vpn ~/.local/share/noctalia/plugins/pia-vpn
noctalia msg plugins enable lmaule/pia-vpn
```

Then add **PIA VPN** to a bar from Settings → Bar. You can also add it by hand:

```toml
[widget.pia_vpn]
type = "lmaule/pia-vpn:widget"
```

To add the tile to the control centre, go to Settings → Control Center shortcuts.

## Usage

- **Bar shield**: the colour and icon follow the tunnel state (protected,
  connecting, not protected, signed out, service down). Left click opens the
  panel. Right click connects or disconnects.
- **Panel**:
  - **Sign in**: enter your PIA username (`p1234567`) and password.
  - **Status card**: shows the state, location, VPN IP, public IP, protocol and
    forwarded port, plus a Connect/Disconnect button.
  - **Locations**: search every PIA region and star your favourites.
    Picking a location while disconnected connects to it. While connected, PIA
    moves the tunnel.
  - **Settings**: WireGuard/OpenVPN, port forwarding, allow LAN, and sign out.
- **Keybinds**:

  ```sh
  noctalia msg plugin lmaule/pia-vpn:status all toggle      # or connect / disconnect / refresh
  noctalia msg panel-toggle lmaule/pia-vpn:panel
  ```

## Settings

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `notify_changes` | bool | `true` | Notify on connect, disconnect and drops |
| `connect_on_select` | bool | `true` | Picking a location while disconnected connects to it |
| `label` (widget) | select | `none` | Bar text: none, location, VPN IP or status |

## How credentials are handled

`piactl login` only reads credentials from a file. When you press Sign in, the
plugin writes your username and password to a `0600` file inside its private
(`0700`) data directory (`~/.local/state/noctalia/…/lmaule/pia-vpn`). It hands
that file to `piactl login` and then `shred`s it, whether sign-in succeeds or
fails. If the shell crashes in the middle of a sign-in, the service shreds any
leftover file the next time it starts. The password is never put on a command
line, logged or stored. The plugin makes no network requests of its own. When
it checks whether you're signed in, it filters PIA's account dump down to
`loggedIn` and `username` inside the pipe, so the dump's password and token
fields never reach the plugin. After
sign-in the PIA daemon keeps its own auth token, the same way the official app
does. **Sign out** runs `piactl logout`, which discards that token.

## Files

- `bin/pia.sh`: the engine. It wraps `piactl` and prints one JSON object per
  call. `watch` streams status lines, and it also works on its own:
  `bin/pia.sh status`.
- `service.luau`: runs the status stream and publishes it to shared state.
- `widget.luau`, `shortcut.luau`, `panel.luau`: the UI. They read that shared
  state.
- `shared.luau`: engine calls, state helpers, and region and state labels.
