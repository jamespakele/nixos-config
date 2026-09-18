# nixos-config

NixOS flake for the VM host (`vm`) running **niri** + **Noctalia**.

## Layout

```
flake.nix                      # inputs: nixpkgs 26.05, noctalia (cachix branch)
hosts/vm/configuration.nix     # the VM host config
```

## VM host (nixosConfigurations.vm)

```bash
sudo nixos-rebuild switch --flake /etc/nixos#vm
```

Rebuild from the VM after `git pull` in `/etc/nixos`.

## VM creation (host-side, required for niri)

niri needs a DRM **render node**; default display-only virtio/QXL video has none.
The VM must be created with virgl 3D acceleration:

- Video model: `virtio` with `accel3d='yes'`
- A graphics device providing the host-side EGL context: `egl-headless` with
  `gl='yes'` + rendernode (SPICE-GL does **not** work on Void hosts — the
  `spice` package is built without GStreamer, so QEMU aborts with
  "invalid video codec" on any `video-codec` setting)
- Memory backing: `<memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking>`

Verified working XML snippets:

```xml
<video>
  <model type='virtio' heads='1' primary='yes'>
    <acceleration accel3d='yes'/>
  </model>
</video>
<graphics type='spice' autoport='yes'/>
<graphics type='egl-headless' gl='yes'>
  <gl rendernode='/dev/dri/renderD128'/>
</graphics>
<memoryBacking>
  <source type='memfd'/>
  <access mode='shared'/>
</memoryBacking>
```

With this the guest exposes `/dev/dri/renderD128` and niri logs
`got render node: renderD128` and starts normally.

## Notes

- noctalia is pinned to its `cachix` branch for binary-cache hits; do **not**
  re-add `inputs.nixpkgs.follows` — mixing nixpkgs versions segfaults noctalia
  in `libgmp` (this cost us a debugging session).
- Host user password is hashed in config (`hashedPassword`), not plaintext.