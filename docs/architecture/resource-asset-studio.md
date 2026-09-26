# Resource & Asset Studio — Alpha 3, Step 19

## Overview and Contract

The Resource & Asset Studio turns ZynSign into a complete application inspection
suite. Instead of only showing raw bundle files or static metadata, users can visually
explore app icons, launch screens, localization string files, bundled fonts,
media assets (audio and video), and detect redundant resources in a developer-grade,
accessible interface.

Resource Studio is strictly **read-only**:
- It never modifies, renames, deletes, extracts, signs, or re-encodes any asset.
- All inspections occur within safe, bounded memory limits.
- Bounded header-prefix reads extract image dimensions, font tables, and media durations
  without decoding full bitmaps or loading entire streams into memory.
- Dynamic Type, VoiceOver, Dark Mode, and iPad keyboard navigation are fully supported.

## Architecture and Layers

The implementation follows ZynSign's clean four-layer separation:

### 1. Domain Layer (`ZynSign/Domain/`)
- `ResourceCategory`: Functional categorization (`.icon`, `.launch`, `.image`, `.font`, `.audio`, `.video`, `.localization`, `.other`).
- `ResourceFilter`: Fast multi-filtering (`.all`, `.images`, `.icons`, `.fonts`, `.audio`, `.video`, `.localization`, `.largeFiles`).
- `ResourceSummary`: Immediate count breakdown powering summary cards.
- `ResourceAsset`: Typed models for discovered resources:
  - `AppIconAsset`: Primary icon, alternate icons, multiple resolutions, scales (@1x/@2x/@3x), and device idioms.
  - `LaunchScreenAsset`: Active launch configuration (Storyboard, NIB, Plist, Static Images), storyboard paths, and launch image sets.
  - `ImageAsset`: Common image formats (PNG, JPEG, WebP, GIF, HEIC, SVG, ICNS, CAR) with dimensions and scales.
  - `FontAsset`: PostScript name, family name, style (Regular, Bold, etc.), file size, and standard preview sentence (`"The quick brown fox jumps over the lazy dog."`).
  - `AudioAsset`: Format (MP3, WAV, M4A, AAC, CAF, AIFF, OGG), duration, sample rate, channels.
  - `VideoAsset`: Format (MP4, MOV, M4V), duration, resolution (width × height).
  - `LocalizationFileAsset` & `LocalizationLanguageGroup`: `.lproj` folders, `.strings` and `.stringsdict` parsed key-value entries.
- `ResourceMetadataParsers`: Pure-Swift header scanners:
  - PNG IHDR, JPEG SOF markers, GIF, and WebP chunk dimensions.
  - TrueType / OpenType font `name` table extraction for PostScript name, family, and style.
  - MP4/MOV `mvhd` and `trak`/`tkhd` atom parser for duration and resolution.
  - WAV RIFF header parser for audio duration, sample rate, and channels.
  - Apple `.strings` and `.stringsdict` parser with fallback line scanner.
- `DuplicateResourceDetector`: Informational analysis detecting redundant images, duplicate fonts, identical localization tables, and same-size duplicate files across directories.
- `AssetRelationships`: Logically groups related assets:
  - App Icon Sets (primary and alternate sets with resolution variants).
  - Launch Assets (storyboards, compiled nibs, static images).
  - Localization Groups (string tables grouped across all languages).
  - Font Families (styles grouped under shared family name).
- `ResourceSearchIndex`: Instant in-memory search across filenames, extensions, localization keys/values, fonts, image dimensions, and media formats.
- `ResourceCatalog`: Aggregate catalog containing all assets, summary, duplicates, relationships, and search index.

### 2. Application Layer (`ZynSign/Application/`)
- `ResourceStudioLimits`: Memory and safety bounds (4 KB image headers, 64 KB font headers, 128 KB video headers, 12 MB max image preview, 16 MB font registration, 32 MB audio playback, 64 MB video staging).
- `IPAResourceStudioInspection`: The application use case:
  - `quickSummary(from:)`: Computes initial resource summary in zero milliseconds from bundle structure without reading file bytes.
  - `inspect(recordWithID:)`: Comprehensive deep inspection with bounded prefix reads.
  - `readEntryData(...)`: Bounded on-demand reading of entry bytes.
  - `readStringsEntries(...)`: On-demand parsing of localization string tables.
- `ResourceMediaLoader`: Manages lazy loading, thumbnail generation, bounded memory caching (NSCache), and temporary sandbox staging for video playback.

### 3. Platform Layer (`ZynSign/Platform/`)
- `CoreTextFontRegistrar`: Safely registers in-memory font data dynamically with CoreText (`CTFontManagerRegisterGraphicsFont`) so SwiftUI views render live typography in custom bundled fonts.
- `AudioPlaybackService`: Observable audio player managing playback state, play/pause, scrub, duration, and time updates.

### 4. Presentation Layer (`ZynSign/Presentation/ResourceStudio/`)
- `ResourceStudioModel`: ObservableObject managing loading phases, active tabs, search, filtering, and selected resources.
- `ResourceStudioView`: Main container with searchable bar, filter pills, and navigation.
- `ResourceDashboardView`: Summary cards for Icons, Launch Assets, Images, Fonts, Audio, Videos, and Localization Files, plus duplicate alerts and relationship previews.
- `AppIconStudioView`: Primary icon hero card, alternate icons grid, resolution badges, copy filename, reveal in bundle, full-screen zoom.
- `LaunchScreenStudioView`: Active launch configuration badge, storyboard details, and static launch images.
- `ImageGalleryView`: Responsive thumbnail grid, format filter chips, dimensions/size labels, and zoomable full-screen preview.
- `FontExplorerView`: Typography cards with live preview sentence, size slider, and font inspector.
- `LocalizationStudioView`: Language list, string tables, key search, and side-by-side language comparison sheet.
- `AudioExplorerView`: Audio file rows with play/pause, scrub bar, duration, and size.
- `VideoExplorerView`: Video asset cards with lazy thumbnail, duration, resolution, and native playback sheet.
- `DuplicateResourcesView`: Summary banner of wasted space, duplicate clusters, and file paths.
- `AssetRelationshipsView`: Grouped views for Icon Sets, Launch Sets, String Tables, and Font Families.
- `ResourceInspectorSheet`: Comprehensive read-only file inspector detailing Overview, Metadata, and Bundle Location.
- `ResourceStudioComponents`: Reusable UI tokens and components.
- Integrated into `ApplicationDetailView`: Resource & Asset Studio section with summary cards and Quick Action tile.

## Performance Guarantees

1. **Lazy Loading**: Thumbnails are loaded and rendered only when scrolled into view.
2. **Bounded Prefix Reads**: Image dimensions and font metadata are parsed from the first 4–64 KB of file data, avoiding full bitmap decoding.
3. **Memory Bounding**: Full uncompressed video/audio files are never loaded into RAM simultaneously. Videos are staged to temporary sandboxed URLs only upon user request.
4. **Instant Zero-I/O Summary**: The initial dashboard summary on the Application Details screen is derived purely from structural bundle metadata already in memory.
