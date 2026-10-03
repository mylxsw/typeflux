# Ask skill installation contract

GUL-184 keeps skills as instructions and resources. Installing, updating, enabling,
or restoring a skill never creates an execution grant, changes code execution or
folder settings, or bypasses the existing P02 scoped approval checks.

## Source and resource verification

GitHub repository, `tree/<ref>/<path>` and `blob/<ref>/<path>/SKILL.md` links are
accepted over HTTPS. A missing ref uses the repository's default branch. The
installer resolves that ref once with the [commit API](https://docs.github.com/en/rest/commits/commits#get-a-commit),
then uses the full commit SHA for the recursive tree and every raw download.
Moving a branch during a download cannot mix versions. A branch containing `/`
cannot be disambiguated from a path in this URL format; use its commit SHA instead.

A [truncated tree](https://docs.github.com/en/rest/git/trees#get-a-tree) fails the
entire operation explicitly. We do not silently install a partial tree or attempt
unbounded recursive fetching. Symlinks, submodules and unsupported file modes
inside selected skills fail the operation. Unsafe paths and case-insensitive or
Unicode-normalized duplicate tree paths also fail. Hidden resource files and
hidden skill folders are excluded. Nested skills own their own resources.

Limits are 20 skills per request, 50 files per skill, 1 MB per file, 5 MB per skill
and 50 installed user directory entries. Each download is streamed with a byte
limit, checked against the tree's exact size and Git blob SHA-1, and recorded with
a SHA-256 digest. Git SHA-1 here checks correspondence with the source tree; it is
not a publisher signature or a trust endorsement. Raw downloads are never executed.

## Atomic publication and recovery

Downloads are staged beside the library. Under a filesystem lock shared by all
application mutations, the installer copies the current library into a sibling
snapshot, moves each replaced skill into `.previous/<name>`, and moves all staged
skills into that snapshot. The live library is untouched during these moves.
Only after every move succeeds does macOS `renameatx_np(RENAME_SWAP)` atomically
publish the directory. Initial installation uses a same-volume directory rename.
Unsupported filesystems fail rather than falling back to partial publication.

Any failure before publication leaves the previous live library byte-for-byte
unchanged, including its existing backups. Cancellation is checked before entering
the synchronous publication transaction. Process termination before publication
can leave a hidden staging/snapshot directory; it is never loaded as a skill.
Termination after the atomic swap leaves a complete new library and can leave
the old snapshot alongside it. These orphaned sibling directories may be removed
when the app is stopped. Power-loss durability/fsync is not guaranteed.

The cost is a copy of the current library during each mutation, plus one previous
version per replaced skill. Snapshots include local skills, unrelated resources,
and prior metadata. The store rejects symlinks in the live library before copying.
Application mutations are serialized; external editors do not participate in the
lock and should not modify the library during installation or rollback.

The settings rollback button restores that skill's previous complete folder and
metadata atomically, retaining the displaced version so the action can be undone.
Other skills are preserved. Removal deletes both the current and previous version.

## Frontmatter schema

Yams parses YAML syntax; Typeflux accepts the following bounded schema, not every
valid YAML structure:

- Optional frontmatter begins with `---` and closes with `---` or `...` at column
  zero. Missing closing delimiters and malformed YAML fail validation.
- The root is a mapping with unique scalar keys. `name`, `description`, `version`
  and unknown fields accept scalar values. Scalar spelling is retained rather
  than converted into application types.
- Plain and quoted strings, escaped quotes/colons, comments, multiline scalars,
  literal/folded blocks and YAML chomping are handled by Yams. CRLF and an initial
  UTF-8 BOM are accepted.
- `metadata` accepts one mapping of scalar keys to scalar values.
- `permissions` and `allowed-tools` accept either a scalar or a list of scalars
  (flow or block style). They are recorded as declarations, never grants. A scalar
  declaration is retained whole, without guessing a permission grammar.
- Anchors, aliases, merges, custom tags, complex keys, duplicate keys, nested
  objects, lists in other fields, and headers over 32 KiB are rejected.
- Name normalization and existing description/body limits remain compatible:
  ASCII slug up to 64 characters, description up to 300, body up to 20,000.
  A missing name falls back to the folder; an empty description falls back to the
  first non-heading line. An empty body or invalid slug is rejected.

Malformed installed local skills are excluded from the list. Installation reports
localized errors distinguishing malformed YAML, unsupported structures and invalid
skills. Existing local files are not rewritten by parsing.

## Metadata, overwrite and enablement

`.source.json` schema 2 records the original URL, repository, requested ref,
immutable commit, source folder, installation date, a fresh installation UUID,
declared version, resource manifest (relative path, bytes, SHA-256) and declared
permissions. It has no field for granted permissions or approval receipts.

Legacy metadata remains readable through optional new fields. Missing commit and
identity stay unknown and are shown as such; an explicit update writes schema 2.
Rollback can restore the original legacy folder and metadata without inventing
provenance. Every new installation/update receives a fresh identity, even when its
name or source matches an existing installation.

Same-name installs deliberately replace the user skill (or override a built-in),
as explained in the install sheet. A local skill whose folder differs from its declared name is moved to the canonical
name during replacement; multiple local folders declaring that name fail explicitly.
Duplicate names within one request are rejected.
Updates and rollback preserve the existing name-based disabled preference. Disabled
skills are neither advertised nor loadable until explicitly enabled. Explicit
removal clears that preference, so a later reinstall starts enabled; enabling only
offers instructions and does not authorize execution.

## Dependency decision

[Yams 6.2.2](https://github.com/jpsim/Yams/tree/6.2.2) is pinned in Package.swift and
Package.resolved. It provides tested scalar, quoting and block semantics instead
of maintaining a partial handwritten YAML parser. It adds one Swift target and
the bundled CYaml C target, with no additional package dependencies, services or
runtime network access. Costs are extra dependency compilation, binary code and
upstream security/update maintenance. Only bounded frontmatter enters this parser;
the AST is validated against the schema above without constructing arbitrary types.

Yams and bundled libYAML use the MIT license. Their complete notices are included
in `Sources/Typeflux/Resources/ThirdPartyNotices-Yams.txt` so packaged applications
retain the license text. No permission framework, engine, database or API changes
are part of this dependency addition.
