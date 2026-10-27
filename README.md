# Simple Scan on the scanner portal (prototype)

`simple-scan/` is a clone of GNOME Simple Scan (upstream bfa17c8, 50.0) with branch
`scanner-portal`: commits that put libsane behind a `ScanBackend` interface and add
`PortalBackend`, which talks to the draft `org.freedesktop.portal.Scanner` interface. This
directory holds only the application port, its flatpak manifests and test results. The portal
itself is in https://github.com/cschalle/flatpak-scanner-portal.

## Where the portal code is

The portal is developed in https://github.com/cschalle/flatpak-scanner-portal. The files below
are from the negative-vibes repository, `../negative-vibes`, and may not all have moved yet:

- `docs/scanner-portal/PROPOSAL.md`: the proposal, with what was tested and what is open.
- `docs/scanner-portal/org.freedesktop.portal.Scanner.xml` and
  `org.freedesktop.impl.portal.Scanner.xml`: the draft D-Bus interfaces.
- `docs/scanner-portal/HARDWARE-TEST.md`: the hardware test.
- `crates/nv-sane-portal` (client) and `crates/nv-portal-proto` (prototype service).
- `tests/` and `tools/portal-hw-check.sh`: the scenario checks that run against any frontend.

The C frontend and the GNOME and GTK dialogs are in
https://github.com/cschalle/flatpak-scanner-portal as patch series for xdg-desktop-portal,
xdg-desktop-portal-gnome and xdg-desktop-portal-gtk, together with the RPM build script. The
branches they come from are in clones kept in `../portal-research`, along with the flatpak
repository; those branches are not pushed.

The port follows the draft as of the second change round (automatic values as the vardict
`{'auto': true}`, a `frame` number on `FrameEvent`, `type` in the scanner info) and the two-phase
listing (`UpdateScanners`). Simple Scan asks for all scanners with no capability filter, and
it skips scanners whose type is `virtual device`, so the SANE `test` backend is invisible to it.

## Build and run

Build from this directory (needs GNOME Platform/Sdk 49):

    flatpak-builder --force-clean --disable-rofiles-fuse build-fp org.gnome.SimpleScan.PortalTest.json

The manifest has no `--device=all` and no `--share=network`. With a desktop that has the portal
installed, `org.gnome.SimpleScan.Portal.json` builds the app that uses it; install it from a
local repository with `--repo` and `--default-branch=portal`.

Without the portal on the desktop, start the prototype service on the host (test backend:
`SANE_CONFIG_DIR` with only `test` in `dll.conf`, `NV_SANE_ALLOW_VIRTUAL=1`,
`nv-portal-proto --select test:`; for a real scanner a `dll.conf` that lists only that scanner's
backend), then

    flatpak-builder --run build-fp org.gnome.SimpleScan.PortalTest.json simple-scan --debug

`SIMPLE_SCAN_BACKEND=portal` and `SIMPLE_SCAN_PORTAL_BUS_NAME` are set by the manifest. Use
`--env=GSETTINGS_BACKEND=memory` and XDG_* overrides to leave `~/.var/app` alone. A scan writes
autosaved pages to `~/.var/app/org.gnome.SimpleScan/cache/simple-scan/autosaves/` whatever the
overrides are.

Never open all SANE devices with the system configuration on a Plustek OpticFilm 8200i: the
stock `genesys` entry for it resets the scanner. Use a private `SANE_CONFIG_DIR`.

## Git policy

The commit rules are the ones adopted from git-stage-batch for the negative-vibes repository and
used for every clone here.

- **No `Co-Authored-By` trailer and no other AI attribution line**, on commits or in pull
  request descriptions.
- **Subject:** `component: Summary`, at most 72 characters, in the imperative, with no trailing
  period. The component is the file, area or class the change is in.
- **Body:** lines of at most 75 characters. Declarative, present tense, starting with "This
  commit …". It explains why, not only what, and states no history that did not happen.
- **One logical change per commit.** Every commit builds on its own. Split a mixed working tree
  into commits by hunk (`git stage-batch`, or `git add -p`) and check each result compiles.
- **Tests:** the message says what was tested and what was not, and claims no result before it
  has been run. Measurements for anything that touches scanning or the pipeline.
- Write the message to a file and commit with `git commit -F file`. Check the widths first, and
  do not chain the commit after a check that only prints.
- Nothing is pushed until it is asked for.
