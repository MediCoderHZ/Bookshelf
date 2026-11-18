# App Review notes — draft

Replace the product name and reviewer contact details with final App Store Connect values. No account credentials are required to use the app.

## Suggested notes

This is a native macOS application for organizing book metadata. It is not an ebook reader and does not access accounts on ebook platforms.

1. Click + to manually add a book. A title is sufficient; other fields are optional.
2. Switch between list/grid views. Select a book to view information, notes and organization. A book may belong to multiple collections.
3. Use the wand button to look up a title or ISBN via Douban, Goodreads, Open Library, or all enabled sources. Queries are sent only after Search. Results and failures are grouped by source; disabled translators are excluded. Select a candidate to fetch and preview the edition details, then fill the editor and Save. Missing or different ISBNs show a warning. Try Douban ISBN 9787544270878 or Goodreads ISBN 9780743273565. Search coverage and website availability vary.
4. Open Settings → Files & Database → Manage Metadata Translators to enable or disable a source. Open the translators folder to see the files beside the database.
5. In More Actions, choose Reload or Import Translator Rules. Check the target site and version before importing. A replacement preserves the existing enable setting. Use the custom rule’s context menu to export or remove it.
6. Settings offers JSON backup export and an import conflict preview. Conflicts default to Skip; each record can be added separately, used to fill blanks, or used to update bibliographic fields while preserving personal organization and notes. Different valid ISBNs cannot overwrite each other. Backups include Trash state, field provenance and smart collection definitions. Versions 1–8 remain readable; exports use version 9, including empty collection hierarchies and standalone/child notes. Smart collection imports can be disabled; local definitions with the same ID or name are preserved. File access is limited to locations selected by the user.
7. Privacy information is available in Settings. The production configuration supplies public support and privacy policy links. Imported rules never execute JavaScript, read browser cookies, log into websites or bypass restrictions. There is no remote code-update service. Library backups and translator exports are separate.

The library is stored locally. There is no developer-hosted account or sync service, advertising or analytics SDK. Outbound requests support optional bibliographic lookup.

The library header's Advanced Filter (Option-Command-F) combines local metadata conditions using All/Any and previews matches. Save the conditions as a named Smart Collection for dynamic sidebar results. Editing book metadata updates membership automatically. Edit/remove definitions through the sidebar; removing a definition preserves books. Creating, editing and removing smart collections support Undo/Redo. Filters never send queries to online providers.

## Collections and notes

Right-click a collection to create a subcollection, rename/move it, or remove the subtree. Removal preserves books and notes and supports Undo/Redo. The parent shows direct members by default; Include Subcollections includes descendants without duplicating items. Cycles and missing parents are rejected. Ordinary collection names remain unique throughout the library for backward compatibility.

The toolbar's New Note menu creates standalone or child notes. Notes use a native rich-text editor directly in the right pane. The default surface fills the pane and contains only a formatting toolbar and the editable body; metadata fields and the persistent status footer are hidden. New notes are created immediately and edits save locally as text changes; no separate editing sheet is used. Conflicting saves retain a recoverable local draft and offer retry or Save as New Note, without overwriting newer content. Standalone notes can belong to several collections; child notes belong to one book. Existing names, tags and memberships remain stored; editing the body does not clear them. Note rows provide Trash through their context menu. The sidebar provides All Notes, Standalone Notes and Note Trash. Search matches note text and tags, and book searches also match child-note content. Legacy single-field notes remain book remarks and can be explicitly converted into a child note with Undo.

Notes support Trash, Restore, confirmed permanent deletion, and Undo/Redo. Trashing a book makes its child notes read-only until the book is restored; permanently deleting a book also deletes its child notes. Merging books transfers child notes to the primary record, with reversible associations. JSON import previews show hierarchies and note actions. Existing note IDs retain local content; newly imported records remap parent IDs according to the selected book action.

## Library maintenance

Multi-select books and choose Batch Edit in the inspector or context menu. Tags, publisher, publication date, edition and language can be edited together. Fields default to Keep; bibliographic fields offer Fill blanks, Replace and Clear. Review differences for each selected book before Apply. Untouched values, notes, unrelated memberships and provenance remain intact; edited bibliographic fields are marked as manual. A batch is one Undo/Redo action. Concurrent changes to selected books abort the batch so users can review again. Trash records must be restored before editing.

Metadata lookup and web extraction open a field comparison before filling the editor. Only empty fields are selected by default; missing incoming fields never clear existing values. Save the editor to commit.

The sidebar has Duplicates and Trash. Multi-select duplicate records, choose Organize Selection → Merge, then choose the primary record and values by field. Notes, tags, collections and series are combined; other originals move to Trash. Different valid ISBNs cannot merge.

Deletion moves records to Trash, preserving metadata and notes. Restore is available; permanent deletion requires confirmation and cannot be undone. Add, edit, import, organize, trash, restore and merge support native Undo/Redo within the current window session. Undo history does not persist after quitting; Trash does.

Notes use a native editable attributed-text document in the right pane. Typing Markdown markers converts headings, emphasis, lists, quotes, code and links directly into formatted content. There is no edit/preview mode switch. Automatic conversions can be undone independently. The toolbar applies formatting directly; links use an inline popover. Native input-method composition is not reformatted mid-composition. New notes derive their display name from the first content line; existing fixed names are preserved without showing a name field. Existing notes are not rewritten on opening. Actual edits serialize to Markdown in the existing local storage and JSON backup, with syntax normalized as needed. Images retain alt text and their destination without loading resources; raw HTML is inert and only http, https and mailto links are clickable. No extra permissions are requested.

## Before submitting

Add real reviewer contact details, verify the notes against the signed build and confirm privacy answers for the external provider. Final name and pricing are pending; do not promise free/paid/subscription terms until decided.
