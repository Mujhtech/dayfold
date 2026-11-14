# Dayfold icon

The editable Icon Composer document is [`AppIcon.icon`](../../dayfold/dayfold/AppIcon.icon). It contains four vector layers: calendar page, folded corner, bindings, and highlighted day. The deep teal background and material settings are editable in Icon Composer.

Open with the Icon Composer bundled inside Xcode. This draft was saved and checked with Icon Composer 27.1. The standalone copy installed on this Mac is an older version.

`sources/` contains the original SVG artwork. These SVGs match the assets imported into the document. When changing source geometry, replace the corresponding image in Icon Composer and save the document. Icon Composer owns the material, appearance and layer-order settings in `icon.json`.

`previews/` contains actual Icon Composer exports: default, dark, tinted, 32 px, 64 px, and design generation 26. The tinted export is an example system tint, not a fixed brand appearance.

Xcode automatically includes the document through the target's synchronized folder. Both build configurations already select `AppIcon`. The empty legacy asset-catalog slot is superseded. The authoritative build passed on 7 November 2026 and produced `AppIcon.icns`, `Assets.car`, and matching Info.plist icon fields while retaining macOS 14.0 as the deployment target. Strict code-signature verification passed. Build evidence: `.build/evidence/icon-build.log`.

This is the first folded-calendar design draft. No menu-bar symbol was changed.

The running Dock initially retained a generic icon despite correct bundle resources and LaunchServices metadata. A targeted refresh of this development bundle (`touch` on the `.app` directory, then `lsregister -f` on that exact bundle) followed by a graceful relaunch resolved it; the owner confirmed the teal calendar icon appeared on 7 November 2026. No global icon-cache purge or runtime icon override was needed.

The app UI uses the same color family: the named `AccentColor` asset is deep teal `#2F6B5F` in light appearance and mint `#A7D9C6` (matching the fold) in dark appearance. `DayfoldAppearance` supplies this tint to all app scenes and sheets; custom selection/focus styling uses `Color.dayfoldAccent`. Calendar identity colors remain independent.
