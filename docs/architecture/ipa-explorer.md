# IPA explorer

The IPA explorer is a read-only browser for one library package. It is reached
from an application’s detail screen, and from the signing screen, when that
record’s artifact is available. It does not extract the package, write to it,
sign it, or run anything inside it.

## What is listed, and what is read

The tree, the statistics card, search, and the resource browser are projections
of one `BundleContents` value. That value still comes from a single entry-table
read through `IPABundleContentsInspection` and the existing `ArchiveReader`.
Listing a folder does not read the files inside it. A symbolic link is named
and not followed. An entry the reader does not model is listed and left alone.
An unknown file is still listed, as a generic file.

Opening a file, a framework, or an extension is a separate, explicit request.
`IPABundleEntryInspection` opens the same archive boundary, reads only the
entries that page names, and closes the reader on every path, including
failure. A content failure becomes an unavailable preview. A failure to open
the library record or the package is still a thrown error. A foreign error is
reduced to a fixed sentence; its text is not shown.

## Bounds

A preview never raises the archive policy’s own ceiling.

| Preview | Bound |
|---|---|
| Text | 256 KiB, then clipped for display |
| Property list and profile | 1 MiB |
| Mach-O header prefix | 256 KiB |
| Image | 4 MiB; a larger declared size is refused and not read |

A complete entry whose declared sizes fit the bound is read through
`readEntryData`, so the container checksum still applies. A larger entry is
read through `readEntryPrefix`. That prefix does not claim the whole-entry
checksum. Deflate is expanded only until the bound, from a capped compressed
input. Encrypted and unsupported methods are refused.

## What a page may say

- **Text, JSON, XML, and property lists** are display copies. Pretty-printing
  JSON does not rewrite the file.
- **Images** are decoded in the view from the bytes the use case returned.
  The use case does not decode them.
- **Mach-O** is a header prefix (`MachOPrefixInspector`), not
  `ReadOnlyMachOParser.parse` and not a hex dump. It reports architecture,
  file type, load-command count, encryption-command status, and whether a
  signature command is present. A slice whose header is past the prefix is
  named from the fat table only. A matching magic with a short header is
  unreadable, not guessed. A signature command is not a valid, trusted, or
  installable signature.
- **Frameworks and extensions** are described from the fresh entry table plus
  a bounded `Info.plist`. Version, bundle identifier, and executable name are
  absent when that read does not yield them. Extension entitlements come from
  the embedded profile’s declared property list, not from the executable.
  Arrays are counts, not contents, so a device list is not dumped. The note
  says the profile was declared, not verified.
- **Profiles** whose first byte is `0x30` are unwrapped with
  `CMSStructureReader` and the encapsulated content is read as a property
  list. That is not CMS verification.

## Presentation

iPad uses a split view. iPhone uses a stack. Only expanded folders contribute
rows, and a folder contributes at most 200 rows plus a control that reveals
the next page. Search is an in-memory index built once; an empty query shows
the tree. Hits are capped at 200 for display, with the real total kept.
Highlighting uses a case- and diacritic-insensitive search on the original
name. A folder hit includes that folder and its immediate children, not every
descendant.

The only actions are View Details, Reveal in Tree, Copy Path, and Copy
Filename. Copy copies the package-relative display path (`Payload/Example.app/…`),
not a sandbox URL. There is no edit, delete, rename, extract, export, or sign
action.

Bundle size is the sum of sizes the package declares. It is not a measurement
taken by reading every file.
