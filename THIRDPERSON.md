# Third-person camera mod (GTA San Andreas style)

A third-person camera mod for the original GoldSrc Half-Life, built on top of
[hlsdk-portable](https://github.com/FWGS/hlsdk-portable). The mouse orbits the camera,
movement is camera-relative, and the weapons fire exactly at the crosshair.

The mod is client-side logic in `cl_dll/tp_camera.cpp`, hooked into the SDK in a few places
(see [How it works](#how-it-works)).

## Status

- Tested on Half-Life (Steam, Linux, engine build 10211) on Artix Linux, singleplayer.
- Windows and Xash3D FWGS builds: not tested yet.
- Multiplayer: not tested and out of scope.

## Features

- Orbit camera with an adjustable shoulder, height and distance, all with smooth easing.
- Camera-relative movement. The body turns cosmetically towards the movement direction
  (client side only), so the server always receives your aim angles.
- Shot convergence: bullets, the RPG laser, gauss and egon beams land on the crosshair
  instead of on the line of sight of the character's eye.
- Full vertical look up to 89 degrees (the stock engine limit; allowing 90 breaks
  walking), and proper 3D swimming.
- Automatic first person when the camera has no room behind the character
  (backing into a wall), and back to third person when there is space.
- Crouch auto-adjust: the camera rises and comes closer while crouch is held.
- `tpaim`: an aim mode with a tighter camera and the body locked to the crosshair.

## Controls

| Command | Default key | Description |
|---|---|---|
| `cl_tp_toggle` | Z | Toggle first / third person |
| `cl_tp_swapshoulder` | X | Switch the camera to the other shoulder (eased) |
| `tpaim` | Alt | Toggle aim mode |

The default keys are bound once on the first run and saved in `config.cfg`, so you can rebind
them freely. To apply the defaults again: `cl_tp_binds 0` and restart the game. Some Linux
window managers grab Alt; if so, rebind with `bind <key> tpaim`.

## Console variables

All variables are archived (saved in `config.cfg`). Defaults apply to a clean install only.

| Variable | Default | Description |
|---|---|---|
| `cl_tp_enable` | 1 | 0 disables the mod (stock first person) |
| `cl_tp_dist` | 100 | Camera distance |
| `cl_tp_shoulder` | 20 | Camera shoulder. The **sign** sets the side in every stance |
| `cl_tp_height` | 0 | Vertical camera offset (positive = up) |
| `cl_tp_turnspeed` | 1000 | Cosmetic body turn speed, degrees per second |
| `cl_tp_easetime` | 0.25 | Easing time in seconds for shoulder, height and distance (0 = instant) |
| `cl_tp_aimfix` | 1 | Converge shots onto the crosshair |
| `cl_tp_autoadjust` | 1 | Use the crouch values while crouch is held |
| `cl_tp_crouch_shoulder` | 20 | Shoulder while crouching (magnitude only) |
| `cl_tp_crouch_height` | 20 | Height while crouching |
| `cl_tp_crouch_dist` | 75 | Distance while crouching |
| `cl_tp_aim_shoulder` | 15 | Shoulder in `tpaim` (magnitude only) |
| `cl_tp_aim_height` | 0 | Height in `tpaim` |
| `cl_tp_aim_dist` | 48 | Distance in `tpaim` |
| `cl_tp_aim_crouch_height` | 20 | Height in `tpaim` while crouching and `cl_tp_autoadjust 1` |
| `cl_tp_autofp` | 1 | Automatic first person when the camera has no room |
| `cl_tp_fp_in` | 24 | Free space below which it switches to first person |
| `cl_tp_fp_out` | 40 | Free space from which it returns to third person |
| `cl_tp_binds` | 0 | Internal: version of the default bindings already applied |

Stance priority for the camera values: `tpaim`, then crouch (with `cl_tp_autoadjust 1`),
then standing.

## Quick start

From a fresh clone on Linux, one command builds, packages and installs the mod:

```bash
git clone --recursive https://github.com/MrPingu07/hl-thirdperson
cd hl-thirdperson
tools/setup-linux.sh --deps --install
```

`setup-linux.sh` updates the submodules, optionally installs the build dependencies
(`--deps`), builds 32-bit and packages into `dist/hltps`. With `--install` it also copies
the result into the Half-Life folder, which it autodetects from Steam's
`libraryfolders.vdf` (override with `--hl-dir DIR` or `HL_DIR`), and links the retail menus
and intro video into it. Without `--deps` it only prints the exact dependency command for
your distribution.

## Building manually (Arch / Artix, 32-bit)

Half-Life is a 32-bit game, so the binaries must be 32-bit. Enable the `lib32` repository in
`/etc/pacman.conf` first.

```bash
sudo pacman -S --needed gcc-multilib lib32-glibc cmake git python
git clone --recursive https://github.com/MrPingu07/hl-thirdperson
cd hl-thirdperson
LDFLAGS="-static-libstdc++ -static-libgcc" ./waf configure
./waf build
```

The static `libstdc++` avoids `GLIBCXX not found` errors on other distributions.

## Packaging and installing

```bash
tools/package-linux.sh              # builds and creates dist/hltps and dist/hltps-linux.zip
tools/package-linux.sh --install    # same, then copies the mod into your Half-Life folder
```

`--no-build` packages the existing `build/` without rebuilding, and `--no-zip` skips the
archive. Environment variables: `HL_DIR` (Half-Life directory, default
`~/.steam/steam/steamapps/common/Half-Life`) and `MOD_NAME` (default `hltps`). `--install`
also runs `link-game-content.sh` in the installed folder (see below).

The resulting layout:

```
hltps/
  liblist.gam
  dlls/hl.so
  cl_dlls/client.so
  link-game-content.sh
```

### Linking the retail menus and intro (run once)

GoldSrc finds most content (maps, models, sounds, configs) by searching `valve/` as a
fallback, which is why the campaign plays straight away. A few paths are read directly out of
the game folder instead, with no fallback, so a fresh mod folder starts with a bare menu, no
intro video and no Options dialogs:

| Path | What it holds |
|---|---|
| `resource/` | the main menu, the decorated background, the UI scheme and icons, and the Options dialogs |
| `media/` | the startup intro videos |
| `gfx/` | shell graphics the UI loads up front (palette, cursors) |
| `logos/` | the spraypaint logos listed in the Options tab |
| `titles.txt` | the on-screen chapter titles |

`link-game-content.sh` creates symbolic links to the retail copies of those, so the mod looks
and behaves like the retail game without copying or shipping any Valve asset. Nothing in
`valve/` is modified. `tools/package-linux.sh --install` runs it for you; otherwise run it
once from inside the mod folder:

```bash
cd <Half-Life>/hltps
./link-game-content.sh
```

(If your unpacking tool dropped the executable bit, run `bash link-game-content.sh` instead.)

Re-run it after a Half-Life update or a Steam "Verify integrity of game files"; both leave the
mod folder alone, so the links survive. `./link-game-content.sh --unlink` removes them again.

Launch Half-Life with the Steam launch options `-game hltps -console`. The mod folder is
separate from `valve/`, so Steam file verification never touches it. You need your own copy of
Half-Life; no game assets are included here.

## Releasing

Releases are built by CI on a tag. Pushing a `v*` tag runs
`.github/workflows/release.yml`, which compiles 32-bit in the Steam runtime (scout) chroot
for maximum compatibility and attaches the packaged zip to a GitHub Release:

```bash
git tag v0.2
git push origin v0.2
```

The zip is named `hltps-<version>-linux.zip`, where the version comes from `git describe`.
The workflow can also be run manually from the Actions tab.

## How it works

The server always receives the converged aim angles in the `usercmd`, so weapons, `+use`,
ladders, swimming and the RPG laser all behave naturally. The body orientation you see is a
client-side effect applied to the local player entity before rendering.

`cl_dll/tp_camera.cpp` holds all the logic. The SDK files are touched only at these points:

| File | Change |
|---|---|
| `cl_dll/input.cpp` | `TP_Init()` in `InitInput`; `TP_ApplyMove()` at the end of `CL_CreateMove` |
| `cl_dll/in_camera.cpp` | `CL_IsThirdPerson` returns `TP_IsThirdPerson()` |
| `cl_dll/view.cpp` | `TP_UpdateAuto()` and `TP_CalcCamera()` replace the stock camera block in `V_CalcNormalRefdef`; `TP_ApplyBodyYaw()` after the local player pitch adjustment |
| `cl_dll/ev_hldm.cpp` | `TP_OverrideShot()` in `EV_HLDM_FireBullets`; `TP_OverrideAngles()` in the events that copy `args->angles` and wherever `GetViewAngles` is used (egon beam) |

## Known limitations

- Server-side projectiles (crossbow bolts, RPG rockets, grenades) leave from the eye along the
  converged direction, so their trajectories may not match the crosshair exactly at close range.
- Binaries are currently built for Linux only.

## License

This repository inherits the license of the Half-Life SDK (see `LICENSE`). Half-Life and its
assets belong to Valve; they are not included.
