# FoldForm dashboard and design library

Status: draft for review. Date: 2026-09-25.

## Goal

FoldForm opens on a clean dashboard listing every design you have made. From it you can open any
design, start a new one, and manage the collection. Today the app saves nothing and every launch
starts from the flat plate, so this work adds a save/load layer as well as the screens.

## Decisions already made

- Each design autosaves and reopens with its **shape, colours, corner style and camera view**.
  Undo history is **not** kept: closing a design forgets its undo steps.
- The dashboard has: live thumbnails, rename, duplicate, delete, search, sort, favourites, folders,
  templates and a stats header. It should look polished.
- There is a **collaboration section** (share, see collaborators, live-update) and a **version
  history**. **No backend is built.** Version history is real and stored locally. Collaboration is a
  UI preview on a local stand-in service: it never sends anything to anyone.

## Non-goals

- Any server, account system, networking, or real sharing/sync.
- Saving undo history, the feature-tree history, or a held fold that is still following the hinge.
- Cloud or iCloud storage, import from other CAD formats.

## Phasing

One plan, three phases, each shippable on its own.

1. **Library**: storage, autosave, navigation, the dashboard and all its management features.
2. **Version history**: real, local checkpoints you can restore.
3. **Collaboration preview**: UI on a stub service, clearly labelled as a preview.

## Storage

Location: `Application Support/FoldForm/`.

```
library.json                     folders, sort/filter preferences
Designs/<design-id>.fold/
    manifest.json                name, dates, favourite, folder, part count, template
    content.json                 bodies (by mesh hash), colours, corner style, camera
    meshes/<sha256>.mesh         one binary file per distinct mesh
    thumbnail.png
    versions/                    phase 2
Trash/                           deleted designs, kept briefly so delete can be undone
```

- **Mesh blobs** hold positions, normals and indices as raw little-endian arrays behind a small
  header, named by the SHA-256 of their bytes. Identical meshes are stored once, which matters once
  versions share most of their geometry.
- **Listing the dashboard reads only `manifest.json` and `thumbnail.png`**, so it stays fast with
  many large designs.
- **Writes are atomic.** A save builds the package in a temporary sibling folder, then swaps it in.
  A crash mid-save leaves the previous version intact.
- **A design that cannot be decoded** shows on the dashboard as "Couldn't open" with the option to
  delete it. Its files are never removed automatically.

## What is captured, and how it loads

A saved design is the workbench's bodies as they are after any held folds, in creation order.

- **Capture** reads each body's shape from the fold session's base shapes (folds already baked in),
  the colour of each body in the same order, the corner style, and the camera rig. Colours are
  stored **by body position**, not by ID, because body IDs are regenerated on load.
- **Load** builds a fresh Part Studio with one `ViewportSolidFeature` per saved body ("Body 1",
  "Body 2", …) and applies colours by position. The first body becomes the plate and the rest become
  parts, through the existing `makeSession` path, so no editor logic changes. The feature tree is
  therefore a flat list after a reopen. This is consistent with how viewport work is already stored
  (bodies hold meshes, not parametric sketches).
- **New designs** store only a template (`PartProfileKind`: flat plate, block, rod, beam, I-beam) and
  no content until the first edit. Opening one calls the existing quick-start loader. There is no
  "blank" template because the editor needs a first body.
- A hold still in progress is not saved. Only folds already held are baked in.

## Autosave

A `DesignSession` object sits between the editor and the library. It saves 1.5 s after the last
change (debounced), when the app goes to the background, and when you return to the dashboard.
Changes are detected from the existing scene revision counter plus style and camera changes. It
also refreshes the thumbnail and the manifest's part count and modified date.

## Thumbnails

Rendered deterministically in CoreGraphics from the saved meshes, not from a screenshot of the live
RealityKit view. A fixed three-quarter view, flat shading with the body colours, painter's-algorithm
ordering, and triangle decimation above roughly 40k triangles. This works headless, is unit-testable,
and needs no offscreen GPU pass.

## Navigation

- `AppRoot` owns the `DesignLibrary` and the current route (dashboard or editor).
- The current `RootView` becomes `EditorView`. Opening a design creates a fresh `AppModel` and
  `ViewportEntities` for it (`.id(design.id)`), so no state leaks between designs.
- The editor gains a back button ("Designs") at the top of its HUD stack and a small pill showing the
  design name. The existing waffle button keeps opening the view-options sheet.
- Dark/light follows the existing `darkMode` setting.

## Dashboard screen

- **Header:** large "Designs" title, a "+" button, and a stats row of four tiles: designs, parts,
  favourites, edited this week.
- **Search and sort:** a search field (name match) and a sort menu: last edited, name, date created.
  The sort choice is remembered.
- **Filters:** a chip row of All, Favourites, each folder, and "+ Folder". A design is in at most one
  folder. Deleting a folder moves its designs back to the top level.
- **Grid:** adaptive cards (about 160 pt minimum). Each shows the thumbnail on a soft gradient
  backdrop, the name, the relative edit time, a favourite star, and a folder tag.
- **Card actions** (long-press): Open, Rename, Duplicate, Favourite, Move to folder, Version history
  (phase 2), Share (phase 3), Delete.
- **Delete** asks for confirmation, moves the design to `Trash/`, and shows a toast with Undo for a
  few seconds. Trash is emptied on the next launch.
- **New design:** a template sheet with a small preview per template.
- **Empty and error states:** a friendly first-run screen with a "Start your first design" action.
- **Style:** rounded 20 pt cards, translucent materials and SF Rounded titles to match the existing
  HUD, generous spacing, subtle shadows in light mode. The iPhone Duo spans two panels; the layout
  keeps cards off the crease if the existing `ScreenCrease` information can be used from SwiftUI.

## Phase 2: version history (real, local)

- Save a **named version** manually (with an optional note), and get an automatic checkpoint when
  you close a design that has changed since its last version. Automatic ones are capped at 20 and
  the oldest are pruned; named ones are never pruned automatically.
- A version is a copy of `content.json` plus a thumbnail under `versions/<id>/`. Mesh blobs are
  shared with the design and other versions, and garbage-collected when no version references them.
- A history sheet lists versions with thumbnail, name, time and a part-count diff. **Restore** first
  saves the current state as an automatic version, then loads the chosen one, so a restore can itself
  be undone.

## Phase 3: collaboration preview (no backend)

- A `CollaborationService` protocol covers collaborators, invitations, activity and incoming
  changes. The only implementation, `LocalPreviewCollaborationService`, returns sample people and
  activity and never touches the network.
- UI: a "Shared" filter on the dashboard, a Share sheet per design (invite by email, role picker,
  people list), presence avatars in the editor, and an activity feed that will also list versions.
- **Honesty rules:** every collaboration screen carries a visible "Preview: not connected to a
  server" banner, sample people are marked "Sample", and inviting someone stores the entry locally
  only and sends nothing. There is no share link, because it could not work.
- A later backend would implement the same protocol. Merging simultaneous edits is out of scope and
  is a separate design.

## Code layout

New: `Library/DesignManifest.swift`, `DesignContent.swift`, `MeshCoding.swift`, `DesignStore.swift`
(disk), `DesignLibrary.swift` (observable list, folders, search/sort), `DesignSession.swift`
(autosave), `ThumbnailRenderer.swift`, `VersionStore.swift`, `CollaborationService.swift`;
`Dashboard/DashboardView.swift`, `DesignCard.swift`, `StatsHeader.swift`, `FolderBar.swift`,
`TemplatePicker.swift`, `VersionHistoryView.swift`, `ShareView.swift`.
Changed: `FoldFormApp.swift` (`AppRoot`, `EditorView`, back button), `AppModel.swift`
(`loadContent`, `captureContent`), `RealityViewport.swift` (capture and load hooks, change signal).
`project.yml` already includes the whole `FoldForm` folder; the project is regenerated with xcodegen.

## Testing

Unit tests (no live simulator UI tests, per the standing rule about not disturbing the emulator):

- Mesh coding round trip and hash stability; identical meshes share one file.
- Store round trip in a temporary directory; a truncated write leaves the previous save readable; a
  corrupt package reports an error and is not deleted.
- Library operations: create, rename, duplicate, favourite, move, delete and undo delete, folder
  delete, plus search, sort and filter as pure functions.
- Capture then load reproduces the same bodies, colours and corner style; a held fold is baked in.
- Thumbnail renderer produces a non-empty image whose pixels differ from the background.
- Version pruning keeps named versions; restore creates the safety checkpoint; blob garbage collection.
- The preview collaboration service makes no network calls and its data is flagged as sample.

## Risks

- **Flattened history on reopen.** Reopened designs have a flat feature list. Acceptable now, and it
  matches how viewport work is already stored.
- **Recreating the 3D scene per open** must not leak; `ViewportEntities.setUp` needs checking for
  retained subscriptions.
- **Large designs.** Thumbnail decimation and fast manifest-only listing keep the dashboard smooth,
  but very large touch-up meshes should be measured.
- **Preview collaboration could look real.** The banner and "Sample" markers are required, not optional.
