# Device compatibility matrix

## Classes, not model names

The matrix is organised by how the app behaves, because that is what a layout
has to survive. ZynSign does not read a device's model identifier, and the Lab
does not start reading one to fill in a report field: it reports the class, and
whether the run was made on a simulator.

| Class | Stands for | What differs |
|---|---|---|
| Compact phone | iPhone SE (2nd/3rd gen), iPhone 8 | The smallest width ZynSign draws; content must stay reachable at the largest Dynamic Type size |
| Standard phone | iPhone 13, 14, 15 | The reference layout |
| Large phone | iPhone 15/16 Pro Max | Grids must use the extra width instead of stretching |
| Tablet | iPad, iPad mini, iPad Air, iPad Pro | Split view, Slide Over, Stage Manager, multiple scenes, keyboard, pointer |

The class is read from the idiom and the layout envelope's width, never from a
model name, and the threshold is the width rather than the height so a device
in landscape is still classified correctly.

## What each class is checked for

Five aspects: layout, performance, memory behaviour, multitasking and
orientation.

| Aspect | Executed on the running device | Not executed |
|---|---|---|
| Layout | The orientations the bundle declares, against what the class uses | Whether the rendered layout actually works — a human pass |
| Performance | Cores, memory and the measured timings from the Performance suite | — |
| Memory behaviour | The device's own thermal report and memory, at the time of the run | Peak footprint during a signing run (Instruments) |
| Multitasking | On a tablet: that multiple scenes are declared | Split view, Slide Over and Stage Manager themselves — a human pass |
| Orientation | The declared set, against what the class uses | The rendered result in each orientation — a human pass |

Every other class reports *Not run*, with the next step: run the Lab on that
device and import its report. A device cannot validate a device it is not.

## The human pass

These need a person with the device, and the Lab refuses to guess at any of
them:

1. **Compact phone, largest Dynamic Type** — every primary screen (Home,
   Library grid and list, Certificates, Profiles, Settings, Compatibility Lab)
   with the text size at maximum. Nothing clipped, nothing unreachable, no
   horizontal scroll traps.
2. **Compact phone, smallest width** — the same screens at the default size.
   ZynSign has no fixed-width grids that break below 375 points.
3. **Large phone** — grids use the extra width; top-edge controls stay
   reachable one-handed.
4. **Tablet, split view** — ZynSign at one-third, one-half and two-thirds
   width; then Slide Over; then Stage Manager with another app in front.
5. **Tablet, keyboard and pointer** — tab order through a form, Return to
   submit, Escape to dismiss a sheet, focus visible on every control.
6. **Rotation** — rotate on every primary screen; no sheet is dismissed by the
   rotation, no scroll position is lost, no progress is restarted.
7. **Background and restore** — background ZynSign mid-import and mid-signing
   run, return to it, and confirm the operation either resumed or reported
   itself as interrupted. No silent loss.

Record the result of each as a Lab overlay, or in the release notes for the
candidate, with the device and iOS version it was made on.

## Memory behaviour

The Lab measures the process's own resident set as the kernel reports it, and
the device's thermal state. Three things it will not do:

- It will not claim a peak-footprint figure. That needs Instruments or a Memory
  Graph during a real signing run.
- It will not raise a memory warning to see what happens. An app cannot
  honestly simulate the system asking it to free memory.
- It will not compare a simulator's memory accounting with a device's.

If the thermal state is `serious` or worse at the time of a run, the Lab warns
that every timing measurement in that report is meaningless.
