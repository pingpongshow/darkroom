# DarkRoom User Guide

DarkRoom is a Mac app for your Immich photo library, with Lightroom-style culling and editing. It never changes Immich itself: everything it does goes through Immich's normal API, so Immich web and the phone apps see the same library.

## Signing in and switching people

- Choose your Immich server (DarkRoom finds servers on your network; you can also type an address) and sign in with your Immich email and password.
- Create a DarkRoom PIN (4–6 digits). Next time, pick your name and enter the PIN, or use Touch ID.
- **Lock** (⌃⌘L) or **Switch User** (⇧⌘U) at any time. After five wrong PINs, the Immich password is required.
- Preferences ▸ Accounts: auto-lock after inactivity, lock when the Mac sleeps, Touch ID, change PIN, sign out.
- **Read-only mode** (Preferences ▸ Accounts): browse, search, Quick Look and export, but DarkRoom refuses every change to Immich (a *Read-only* badge shows in the title bar). Turn it on when you first connect an existing library.

## Browsing

| Key | Action |
|---|---|
| G / E / D | Grid / Loupe / Develop |
| C / N | Compare / Survey selected photos |
| Space or Return | Open the selected photo |
| ← → | Previous / next photo |
| ⌘+ / ⌘− | Bigger / smaller thumbnails, or zoom |
| I | Info overlay with histogram |
| Tab / ⇧Tab | Hide side panels / all panels |
| ⌘F | Search |
| ⌘[ | Back |
| ⌘↩ | Slideshow |
| ⌘Y | Quick Look |
| ⌘/ | All keyboard shortcuts |

Sidebar: Photos, Explore, Map, People, Places, Albums, Sharing, Favorites, Memories, Recently Added, Recently Edited, Tags, Archive, Locked Folder, Duplicates, Bursts, Large Files, Trash.

- **‹ Back** (or Esc) goes from the editor to the photo, and from the photo to the grid, which shows the photo you were on. In a photo or video, swipe left/right with two fingers (on videos, scrub with the progress bar) or use the ‹ › arrows for the previous/next photo. The date bar beside the grid jumps to a year or month; hover to see the full date.
- **Edit** in the title bar (or D, or right-click ▸ Edit Photo) opens the editor: Crop, Rotate, Flip, Heal, Masks, White Balance and every adjustment panel.
- Click a Live Photo (or press Space) to play it.
- Info panel: click the date or location to change it; the people in the photo are listed under Rating (click one to see all their photos).
- People: hover a face and click the eye to hide that person (also hidden in Immich); *Show hidden people* brings them back.

## Search

Type a description ("dog on the beach") for Immich's smart search. The filter button adds people, place, camera, lens, dates, type, rating, favourites and more, or switches to file-name, description or text-in-photo search.

## Organising

- **Rate** 0–5, **favourite** H, **pick / reject / unflag** P / X / U (stored as Immich tags *Culling/Pick* and *Culling/Reject*).
- **Delete** sends items to **Immich's trash** (recoverable). Only *Empty Trash* deletes permanently, after confirmation.
- Albums (⇧⌘A, or drag photos onto an album in the sidebar), tags (⇧⌘T), date & time (⇧⌘D), metadata (⇧⌘M), location (⇧⌘L), stack (⌘G), archive (⌥⌘A), locked folder, Make Still for Live Photos, rotate (⌥⌘← / ⌥⌘→, lossless for videos).
- **⌘Z** undoes organising actions.
- Date, location, description, rating and tags are also **written into the files** (Preferences ▸ General ▸ Metadata). The rewritten file replaces the old one in Immich; the old one is kept hidden so phones don't upload it again.

## Developing (D)

- Panels: Profile & RAW, White Balance, Tone, Presence, Tone Curve, Colour Mixer, Colour Grading, Detail, Effects, Lens Corrections, Transform (Upright), Calibration, Masks, Retouch.
- Crop (R), white-balance picker (W), black & white (V), before/after (\\), masks (M, ⇧M, K), spot removal (Q), auto tone (⌘U).
- **Presets** on the left: hover to preview, click to apply, then drag Amount. ⌃1–⌃9 apply favourite presets anywhere. Import Lightroom `.xmp` presets and `.cube` LUTs; export your own as `.darkroom-preset`.
- **Save** (⌘S) saves and closes the editor; **Cancel** discards unsaved changes and closes it; **Reset** goes back to the last saved version (or the original) and stays in the editor. Leaving the editor in any way with unsaved changes (Back, Esc, arrows, another photo, the view switcher, sidebar, lock, quit) asks Save / Don't Save / Keep Editing. If DarkRoom locks itself while you edit, the changes are kept on this Mac and offered again next time you open that photo.
- Saving: Crop/rotate-only edits of normal (non-RAW) photos use Immich's own edit; anything else creates an **edited version** (`name-edit.ext`) stacked on top of the original, with the original hidden so nothing appears twice. Re-open any time: every slider is where you left it. *Revert to Original* undoes it.
- Merge to HDR (⌃H) and Panorama (⌃M) from a selection.

## Edit in other apps (⌘E)

Right-click ▸ Edit in ▸ (darktable, RawTherapee, Photoshop, Pixelmator Pro, Affinity Photo, GIMP, Krita, Lightroom, Capture One, Preview…). Edit and save, then close the photo: DarkRoom uploads the result as the edited version. Apps that export (Lightroom, Capture One, Affinity, GIMP) export into the folder DarkRoom shows. Tick *Keep editable file* to keep layered files on this Mac (Kept Edits).

## Import (⇧⌘I)

Choose files or folders from any disk (or drop them on the window). DarkRoom shows what's new, skips what's already in Immich, keeps Live Photos and RAW+JPEG pairs together, and uploads in the background (pause and resume from the menu bar). Your files on disk are never changed or deleted.

## Export (⇧⌘E)

JPEG, HEIC, PNG, TIFF or original; size, quality, colour space, metadata (all / no location / copyright only), watermark text or image, file-name template. Save settings as export presets.

## Shortcuts app

"Upload to Immich", "Search Immich" and "Open Album" actions (DarkRoom must be open and unlocked).

## Updates

DarkRoom ▸ Check for Updates… (and automatic daily checks). Updates are signed and notarized, and come from the DarkRoom GitHub releases page.

## Privacy

DarkRoom talks only to your Immich server, Apple's map tiles and the update feed. Previews are cached in `~/Library/Caches/DarkRoom`; originals are downloaded only when you edit or export.
