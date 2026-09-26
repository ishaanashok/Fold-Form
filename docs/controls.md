# Controls

## Dashboard

| Control | What it does |
| --- | --- |
| **+** (top right) | New design from a template |
| Sort button | Last edited, name, or date created |
| Search field | Filters designs by name |
| Chips | All, Favourites, Shared, one per folder; **+ Folder** adds one (long-press a folder to rename or delete it) |
| Tap a card | Opens the design |
| Star on a card | Favourite or unfavourite |
| Long-press a card | Open, Rename, Duplicate, Favourite, Version history, Share, Move to folder, Delete |

Inside a design, the pill at the top ("< name") saves and returns to the dashboard.

## Gestures on the model

| Gesture | Action |
| --- | --- |
| One-finger drag (or mouse drag) | Rotate about the centre of mass. Unlimited, any orientation. |
| Two-finger drag (or Shift-drag) | Pan |
| Pinch (or scroll wheel) | Zoom, smoothed, with a small dead zone |
| Tap a part | Select it |
| Tap a visible sharp edge or vertex, then bend | Yellow marks the persistent selection; tap again to keep the previewed fillet and deselect |
| Read the bottom card while filleting | It shows the current fillet radius in the chosen dimension unit; ordinary folds show the bend angle |
| Double-tap the model | Toggle rounded / sharp fold corner |
| Press and hold a part's face | Duplicate / Copy / Delete menu |
| Press and hold empty space | Paste menu (when something is copied) |
| Drag while sketching | Draw the current tool's shape |

With the **Move** button on, a plain one-finger drag pans instead of rotating (useful with a mouse in
the simulator).

## Left column

Sketch, Undo (Revert), Move and the disclosure button are always visible when flat. The disclosure
opens the remaining tools and closes when you choose one or press the viewport. When the hinge bend
passes the flat threshold, only Lock is shown. It stays visible while a fold or fillet is held and
goes away after the hinge returns to flat.

| Button | What it does |
| --- | --- |
| Pencil | Start or leave sketching |
| Undo circle | Undo the last edit |
| Four arrows | Move mode: a one-finger drag pans |
| Disclosure | Show or hide the additional tools |
| Microphone (disclosure) | Start or stop voice control |
| Sparkles (disclosure) | Open Imagine’s sketch and prompt sheet |
| Wand (disclosure) | Touch up: remove odd bumps and snap to the shape you meant (sketch outlines while sketching, bodies otherwise) |
| Share (disclosure) | Choose STL, 3MF, GLB or OBJ, then use the share sheet |
| Grid (waffle, disclosure) | Opens the view options: planes, origin, dimensions, units, dark mode |
| Lock (while folding) | Hold the current fold or fillet |
| Undo arrow / Reset arrow (disclosure) | Undo the last held fold / clear all folds (available after a fold is held) |
| Red round arrow (disclosure) | Reset everything to the first flat plate |

## Top-right

- **View cube:** tap a face to snap to it. Arrows turn a quarter turn; curved arrows roll in place.

## Sketch toolbar (bottom, while sketching)

Line, Rectangle, Circle, Undo (last shape), **Extrude**, **Remove**, Done. While extruding or removing:
Cancel and Confirm, plus the depth slider on the right edge.

## Imagine sheet

| Control | What it does |
| --- | --- |
| Sketch canvas | Draw a rough concept; the lines are saved as normalized strokes and rendered to an image at Generate |
| Add rectangle / Clear sketch | Add a guide shape without drawing, or erase the sketch |
| Description | Type and edit the design request |
| Describe by voice / Stop dictation | Add a finished spoken sentence to the description; interim words are only shown as a caption |
| Allow removing parts | Explicitly permits a plan to remove a part; the base plate still cannot be removed |
| NVIDIA API key | Save or remove the key in Keychain; the value is never shown after saving |
| Generate | Send the sketch, description, and current design to NVIDIA and apply a validated plan |
| Close | Cancel any request and return to the editor |

Imagine shows Reading sketch, Planning features, and Applying steps while it works. It reports
failures without leaving partial edits, and lists any assumptions after success.

## Readout (bottom-right)

Hinge angle in degrees, its status word, and a `SHARP` tag when the sharp corner is active.
