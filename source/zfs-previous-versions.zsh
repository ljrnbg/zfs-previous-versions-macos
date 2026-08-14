#!/bin/zsh

# =============================================================================
# ZFS Previous Versions for macOS
# Version 0.9
#
# Finder Quick Action for browsing and restoring previous versions of files
# stored on mounted ZFS/TrueNAS shares exposing .zfs/snapshot.
#
# Repository:
# https://github.com/ljrnbg/zfs-previous-versions-macos
#
# License: MIT
#
# No external dependencies required.
# =============================================================================



# =============================================================================
# Configuration
# =============================================================================

SCRIPT_VERSION="0.9"

# Number of parallel SMB metadata requests.
#
# Higher values can significantly improve performance on high-latency SMB/VPN
# connections. 8 has proven to be a good default.
PARALLEL=8

# Restored files are copied here.
RESTORE_DIR="$HOME/Downloads"

# Verify the restored file byte-for-byte against the snapshot after copying.
#
# true:
#   Safest option. The selected snapshot file is read once for copying and
#   once again for verification.
#
# false:
#   Faster for very large files or slow remote connections, but skips the
#   byte-for-byte verification after copying.
VERIFY_RESTORE=true


# =============================================================================
# Localization
#
# English is the fallback language.
#
# To add another language, simply add another set of entries using an
# ISO 639-1 language code, for example:
#
#   I18N[fr.title]='Versions précédentes'
#   I18N[fr.cancel]='Annuler'
#
# No changes to the application logic should be necessary.
# =============================================================================

typeset -A I18N

I18N=(

    # -------------------------------------------------------------------------
    # English
    # -------------------------------------------------------------------------

    'en.title'                  "Previous Versions (v${SCRIPT_VERSION})"
    'en.ok'                     'OK'
    'en.cancel'                 'Cancel'
    'en.restore'                'Restore'
    'en.select_prompt'          'Select a version for:'

    'en.select_one'             'Please select exactly one file.'
    'en.no_folder'              'Please select a file, not a folder.'
    'en.no_symlink'             'Symbolic links are not supported.'
    'en.not_found'              'The selected file could not be found.'
    'en.not_volume'             'The selected file is not located on a mounted volume.'

    'en.no_snapshot_access'     'No ZFS snapshot directory is accessible for the volume “%s”.'
    'en.no_snapshots'           'No ZFS snapshots were found for the volume “%s”.'
    'en.scan_failed'            'The ZFS snapshots could not be scanned.'
    'en.no_versions'            'No previous versions were found for “%s”.'

    'en.temp_failed'            'Temporary files could not be created.'
    'en.restore_dir_missing'    'The restore folder is not available.'
    'en.mapping_failed'         'The selected version could not be resolved.'
    'en.filename_too_long'      'The generated filename would be too long.'
    'en.destination_exists'     'The file “%s” already exists in the restore folder.'
    'en.restore_failed'         'The file could not be restored safely.'

    'en.date_format'            '%Y-%m-%d %H:%M'
    'en.decimal_separator'      '.'
    'en.size_unit'              'MB'


    # -------------------------------------------------------------------------
    # German
    # -------------------------------------------------------------------------

    'de.title'                  "Vorherige Versionen (v${SCRIPT_VERSION})"
    'de.ok'                     'OK'
    'de.cancel'                 'Abbrechen'
    'de.restore'                'Wiederherstellen'
    'de.select_prompt'          'Version auswählen für:'

    'de.select_one'             'Bitte genau eine Datei auswählen.'
    'de.no_folder'              'Bitte eine Datei auswählen, keinen Ordner.'
    'de.no_symlink'             'Symbolische Links werden nicht unterstützt.'
    'de.not_found'              'Die ausgewählte Datei wurde nicht gefunden.'
    'de.not_volume'             'Die ausgewählte Datei liegt nicht auf einem eingebundenen Volume.'

    'de.no_snapshot_access'     'Für das Volume „%s“ ist kein ZFS-Snapshot-Verzeichnis erreichbar.'
    'de.no_snapshots'           'Für das Volume „%s“ wurden keine ZFS-Snapshots gefunden.'
    'de.scan_failed'            'Die ZFS-Snapshots konnten nicht durchsucht werden.'
    'de.no_versions'            'Für „%s“ wurden keine vorherigen Versionen gefunden.'

    'de.temp_failed'            'Temporäre Dateien konnten nicht angelegt werden.'
    'de.restore_dir_missing'    'Der Wiederherstellungsordner ist nicht verfügbar.'
    'de.mapping_failed'         'Die gewählte Version konnte nicht zugeordnet werden.'
    'de.filename_too_long'      'Der erzeugte Dateiname wäre zu lang.'
    'de.destination_exists'     'Die Datei „%s“ existiert bereits im Wiederherstellungsordner.'
    'de.restore_failed'         'Die Datei konnte nicht sicher wiederhergestellt werden.'

    'de.date_format'            '%d.%m.%Y %H:%M'
    'de.decimal_separator'      ','
    'de.size_unit'              'MB'
)


# =============================================================================
# Localization helpers
# =============================================================================

detect_ui_language() {

    local LANGUAGE_CODE=""

    # AppleLanguages reflects the user's preferred UI language more accurately
    # than AppleLocale, which may primarily reflect regional settings.
    LANGUAGE_CODE=$(
        /usr/bin/defaults read -g AppleLanguages 2>/dev/null |
        /usr/bin/sed -En \
            's/^[[:space:]]*"?([A-Za-z]{2,3})([-_][A-Za-z0-9-]+)?"?,?[[:space:]]*$/\1/p' |
        /usr/bin/head -n 1
    )

    # Fallback to AppleLocale if AppleLanguages could not be read.
    if [[ -z "$LANGUAGE_CODE" ]]; then

        LANGUAGE_CODE=$(
            /usr/bin/defaults read -g AppleLocale 2>/dev/null
        )

        LANGUAGE_CODE="${LANGUAGE_CODE%%[_-]*}"
    fi

    LANGUAGE_CODE="${LANGUAGE_CODE:l}"

    print -r -- "$LANGUAGE_CODE"
}


UI_LANG="$(detect_ui_language)"


# Fall back to English if the detected language is not available.
LANGUAGE_TEST_KEY="${UI_LANG}.title"

if [[ -z "${I18N[$LANGUAGE_TEST_KEY]}" ]]; then
    UI_LANG="en"
fi


# Return a translated string.
#
# Example:
#
#   t title
#
# Missing translations automatically fall back to English.
t() {

    local KEY="$1"
    local LANGUAGE_KEY="${UI_LANG}.${KEY}"
    local FALLBACK_KEY="en.${KEY}"

    local VALUE="${I18N[$LANGUAGE_KEY]}"

    if [[ -z "$VALUE" ]]; then
        VALUE="${I18N[$FALLBACK_KEY]}"
    fi

    # Last-resort fallback for missing dictionary keys.
    if [[ -z "$VALUE" ]]; then
        VALUE="$KEY"
    fi

    print -r -- "$VALUE"
}


# Return a translated string containing printf placeholders.
#
# Example:
#
#   tf no_snapshots "$VOLUME_NAME"
tf() {

    local KEY="$1"
    shift

    local TEMPLATE
    TEMPLATE="$(t "$KEY")"

    printf -- "$TEMPLATE" "$@"
}


# =============================================================================
# Native macOS alert helper
# =============================================================================

show_alert() {

    local MESSAGE="$1"
    local STYLE="${2:-info}"

    /usr/bin/osascript - \
        "$(t title)" \
        "$MESSAGE" \
        "$(t ok)" \
        "$STYLE" <<'APPLESCRIPT'

on run argv

    set alertTitle to item 1 of argv
    set alertMessage to item 2 of argv
    set okButton to item 3 of argv
    set alertStyle to item 4 of argv

    tell application "Finder"

        activate

        if alertStyle is "warning" then

            display alert alertTitle ¬
                message alertMessage ¬
                buttons {okButton} ¬
                default button okButton ¬
                as warning

        else

            display alert alertTitle ¬
                message alertMessage ¬
                buttons {okButton} ¬
                default button okButton

        end if

    end tell

end run

APPLESCRIPT
}


# =============================================================================
# Validate Finder input
# =============================================================================

if (( $# != 1 )); then
    show_alert "$(t select_one)" "warning"
    exit 0
fi

FILE="$1"


# Symbolic links are deliberately not supported.
if [[ -L "$FILE" ]]; then
    show_alert "$(t no_symlink)" "warning"
    exit 0
fi


# Directories are currently not supported.
if [[ -d "$FILE" ]]; then
    show_alert "$(t no_folder)" "warning"
    exit 0
fi


# The selected object must be an existing regular file.
if [[ ! -f "$FILE" ]]; then
    show_alert "$(t not_found)" "warning"
    exit 0
fi


# =============================================================================
# Determine the mounted volume automatically
#
# Example:
#
#   /Volumes/TRT-Daten/Projects/example.docx
#
# becomes:
#
#   MOUNT_POINT=/Volumes/TRT-Daten
#   RELATIVE_PATH=Projects/example.docx
#
# No share or server name is hard-coded.
# =============================================================================

if [[ "$FILE" != /Volumes/*/* ]]; then
    show_alert "$(t not_volume)" "warning"
    exit 0
fi


VOLUME_PATH="${FILE#/Volumes/}"
VOLUME_NAME="${VOLUME_PATH%%/*}"

MOUNT_POINT="/Volumes/$VOLUME_NAME"
SNAPSHOT_ROOT="$MOUNT_POINT/.zfs/snapshot"

RELATIVE_PATH="${FILE#$MOUNT_POINT/}"


# =============================================================================
# Validate restore directory
# =============================================================================

if [[ ! -d "$RESTORE_DIR" ]]; then
    show_alert "$(t restore_dir_missing)" "warning"
    exit 0
fi


# =============================================================================
# Validate ZFS snapshot access
# =============================================================================

if [[ ! -d "$SNAPSHOT_ROOT" ]]; then

    show_alert \
        "$(tf no_snapshot_access "$VOLUME_NAME")" \
        "warning"

    exit 0
fi


# =============================================================================
# Enumerate snapshot directories
#
# zsh glob qualifiers:
#
#   N  Allow zero matches
#   /  Directories only
# =============================================================================

SNAPSHOTS=("$SNAPSHOT_ROOT"/*(N/))


if (( ${#SNAPSHOTS[@]} == 0 )); then

    show_alert \
        "$(tf no_snapshots "$VOLUME_NAME")"

    exit 0
fi


# =============================================================================
# Temporary workspace
# =============================================================================

TEMP_DIR=""
RESTORE_TEMP=""


cleanup() {

    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        /bin/rm -rf "$TEMP_DIR"
    fi

    if [[ -n "$RESTORE_TEMP" && -e "$RESTORE_TEMP" ]]; then
        /bin/rm -f "$RESTORE_TEMP"
    fi
}


trap cleanup EXIT


TEMP_DIR=$(
    /usr/bin/mktemp -d -t zfs-previous-versions
)


if [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]]; then
    show_alert "$(t temp_failed)" "warning"
    exit 0
fi


RAW_RESULTS="$TEMP_DIR/raw-results"
VERSIONS_FILE="$TEMP_DIR/versions"
CHOICES_FILE="$TEMP_DIR/choices"
MAPPING_FILE="$TEMP_DIR/mapping"

: > "$RAW_RESULTS"
: > "$VERSIONS_FILE"
: > "$CHOICES_FILE"
: > "$MAPPING_FILE"


# =============================================================================
# Query snapshots in parallel
#
# PERFORMANCE-CRITICAL SECTION
#
# The worker deliberately does as little local processing as possible.
# Each worker only:
#
#   1. builds the snapshot file path
#   2. performs one stat() metadata request over SMB
#   3. writes the raw result
#
# Snapshot-name parsing and sorting happen later in one local processing pass.
#
# Raw result format:
#
#   snapshot-name|mtime|size
#
# If the file does not exist in a snapshot:
#
#   snapshot-name|MISSING|
# =============================================================================

export RELATIVE_PATH


if ! printf '%s\0' "${SNAPSHOTS[@]}" | \
    /usr/bin/xargs -0 -n 1 -P "$PARALLEL" /bin/zsh -c '

        SNAPSHOT="$1"
        SNAPSHOT_NAME="${SNAPSHOT:t}"

        VERSION_FILE="$SNAPSHOT/$RELATIVE_PATH"

        if INFO=$(/usr/bin/stat -f "%m|%z" "$VERSION_FILE" 2>/dev/null); then

            print -r -- "$SNAPSHOT_NAME|$INFO"

        else

            print -r -- "$SNAPSHOT_NAME|MISSING|"

        fi

    ' zsh > "$RAW_RESULTS"
then

    show_alert "$(t scan_failed)" "warning"
    exit 0

fi


# =============================================================================
# Detect actual file versions
#
# Snapshot timestamps are parsed AFTER all SMB requests have finished.
#
# Instead of launching a separate sed process for every snapshot, the complete
# raw result file is processed by ONE sed instance here.
#
# Recognized snapshot names include, for example:
#
#   auto-2026-08-14_21-00
#   periodic-2026-08-14_21-00
#   snapshot-2026-08-14T21:00
#   snapshot-2026-08-14T21:00:30
#
# The processing step adds a sortable timestamp as the first field:
#
#   sort-key|snapshot-name|mtime|size
#
# Snapshot names without a recognizable timestamp receive a fallback sort key
# based on the snapshot name itself.
#
#
# Consecutive snapshots containing the same:
#
#   modification time + file size
#
# are treated as the same file version.
#
# This avoids showing hundreds of identical hourly snapshots.
#
# A missing file resets the comparison so that a later reappearance is treated
# as a new version.
#
# Full hashes are deliberately NOT calculated during scanning because that
# would require transferring every complete snapshot file over SMB/VPN.
# =============================================================================

LAST_MTIME=""
LAST_SIZE=""


while IFS='|' read -r SORT_KEY SNAPSHOT_NAME MTIME SIZE; do

    if [[ "$MTIME" == "MISSING" ]]; then

        LAST_MTIME=""
        LAST_SIZE=""

        continue
    fi


    if [[ "$MTIME" != "$LAST_MTIME" || "$SIZE" != "$LAST_SIZE" ]]; then

        print -r -- \
            "$SORT_KEY|$SNAPSHOT_NAME|$MTIME|$SIZE" \
            >> "$VERSIONS_FILE"

        LAST_MTIME="$MTIME"
        LAST_SIZE="$SIZE"
    fi

done < <(

    /usr/bin/sed -E '

        # Snapshot name contains a recognizable timestamp.
        /^[^|]*[0-9]{4}-[0-9]{2}-[0-9]{2}[T_][0-9]{2}[-:][0-9]{2}/ {

            s/^(([^|]*)([0-9]{4}-[0-9]{2}-[0-9]{2})[T_]([0-9]{2})[-:]([0-9]{2})([-:]([0-9]{2}))?([^|]*))\|(.*)$/\3_\4-\5\6|\1|\9/

            b
        }

        # Fallback for snapshot names without a recognizable timestamp.
        s/^([^|]*)\|(.*)$/~\1|\1|\2/

    ' "$RAW_RESULTS" |

    LC_ALL=C /usr/bin/sort \
        -t '|' \
        -k1,1 \
        -k2,2

)


# =============================================================================
# No versions found
# =============================================================================

FILE_NAME="${FILE:t}"


if [[ ! -s "$VERSIONS_FILE" ]]; then

    show_alert \
        "$(tf no_versions "$FILE_NAME")"

    exit 0
fi


# =============================================================================
# Build the user-facing list
#
# Newest version first.
#
# Example:
#
#   13.08.2026 18:17   —   3,4 MB
#
# Date format and decimal separator are localization settings.
# =============================================================================

DATE_FORMAT="$(t date_format)"
DECIMAL_SEPARATOR="$(t decimal_separator)"
SIZE_UNIT="$(t size_unit)"

typeset -A SEEN_LABELS


while IFS='|' read -r SORT_KEY SNAPSHOT_NAME MTIME SIZE; do

    CHANGE_DATE=$(
        /bin/date -r "$MTIME" "+$DATE_FORMAT"
    )


    SIZE_MB=$(
        /usr/bin/awk \
            -v bytes="$SIZE" \
            'BEGIN { printf "%.1f", bytes / 1024 / 1024 }'
    )


    SIZE_DISPLAY="$SIZE_MB"

    if [[ "$DECIMAL_SEPARATOR" != "." ]]; then
        SIZE_DISPLAY="${SIZE_DISPLAY/./$DECIMAL_SEPARATOR}"
    fi


    DISPLAY_TEXT="$CHANGE_DATE   —   $SIZE_DISPLAY $SIZE_UNIT"


    # Visible labels should normally already be unique.
    #
    # If two versions happen to have identical modification time and size,
    # append the snapshot name only to the duplicate entry so that the
    # selection remains unambiguous.

    if [[ -n "${SEEN_LABELS[$DISPLAY_TEXT]}" ]]; then
        DISPLAY_TEXT="$DISPLAY_TEXT   [$SNAPSHOT_NAME]"
    fi

    SEEN_LABELS[$DISPLAY_TEXT]=1


    print -r -- \
        "$DISPLAY_TEXT" \
        >> "$CHOICES_FILE"

    printf "%s\t%s\n" \
        "$DISPLAY_TEXT" \
        "$SNAPSHOT_NAME" \
        >> "$MAPPING_FILE"

done < <(
    /usr/bin/tail -r "$VERSIONS_FILE"
)


# =============================================================================
# Native macOS version selection dialog
# =============================================================================

CHOICE=$(
    /usr/bin/osascript - \
        "$CHOICES_FILE" \
        "$FILE_NAME" \
        "$(t title)" \
        "$(t select_prompt)" \
        "$(t restore)" \
        "$(t cancel)" <<'APPLESCRIPT'

on run argv

    set choicesPath to item 1 of argv
    set targetName to item 2 of argv

    set dialogTitle to item 3 of argv
    set promptText to item 4 of argv
    set restoreButton to item 5 of argv
    set cancelButton to item 6 of argv

    set choicesFile to POSIX file choicesPath
    set choicesText to read choicesFile as «class utf8»

    set versionList to paragraphs of choicesText


    tell application "Finder"

        activate

        set selectedVersion to choose from list versionList ¬
            with title dialogTitle ¬
            with prompt promptText & return & targetName ¬
            OK button name restoreButton ¬
            cancel button name cancelButton

    end tell


    if selectedVersion is false then
        return ""
    end if


    return item 1 of selectedVersion

end run

APPLESCRIPT
)


# User cancelled the dialog.
if [[ -z "$CHOICE" ]]; then
    exit 0
fi


# =============================================================================
# Map the selected visible entry back to its ZFS snapshot
# =============================================================================

SELECTED_SNAPSHOT=""


while IFS=$'\t' read -r LABEL SNAPSHOT_NAME; do

    if [[ "$LABEL" == "$CHOICE" ]]; then

        SELECTED_SNAPSHOT="$SNAPSHOT_NAME"
        break

    fi

done < "$MAPPING_FILE"


if [[ -z "$SELECTED_SNAPSHOT" ]]; then
    show_alert "$(t mapping_failed)" "warning"
    exit 0
fi


SELECTED_FILE="$SNAPSHOT_ROOT/$SELECTED_SNAPSHOT/$RELATIVE_PATH"


# =============================================================================
# Generate a safe snapshot suffix for the restored filename
#
# If a recognizable timestamp exists:
#
#   auto-2026-08-07_15-00
#
# becomes:
#
#   2026-08-07_15-00
#
# Otherwise a filesystem-safe representation of the complete snapshot name
# is used.
# =============================================================================

SNAPSHOT_SUFFIX=$(
    printf "%s\n" "$SELECTED_SNAPSHOT" |
    /usr/bin/sed -E -n \
        's/^.*([0-9]{4}-[0-9]{2}-[0-9]{2})[T_]([0-9]{2})[-:]([0-9]{2})([-:]([0-9]{2}))?.*$/\1_\2-\3\4/p'
)


SNAPSHOT_SUFFIX="${SNAPSHOT_SUFFIX//:/-}"


if [[ -z "$SNAPSHOT_SUFFIX" ]]; then

    SNAPSHOT_SUFFIX=$(
        printf "%s" "$SELECTED_SNAPSHOT" |
        /usr/bin/tr -c 'A-Za-z0-9._-' '_'
    )

fi


if [[ -z "$SNAPSHOT_SUFFIX" ]]; then
    SNAPSHOT_SUFFIX="snapshot"
fi


# =============================================================================
# Build restored filename
# =============================================================================

FILE_BASE="${FILE_NAME%.*}"
FILE_EXT="${FILE_NAME##*.}"


# Treat files without a meaningful extension as extensionless.
if [[ "$FILE_NAME" != *.* || -z "$FILE_BASE" || -z "$FILE_EXT" ]]; then

    RESTORED_NAME="${FILE_NAME}_${SNAPSHOT_SUFFIX}"

else

    RESTORED_NAME="${FILE_BASE}_${SNAPSHOT_SUFFIX}.${FILE_EXT}"

fi


DESTINATION="$RESTORE_DIR/$RESTORED_NAME"


# =============================================================================
# Guard against the common 255-byte filesystem filename limit
# =============================================================================

NAME_BYTES=$(
    printf "%s" "$RESTORED_NAME" |
    /usr/bin/wc -c |
    /usr/bin/tr -d ' '
)


if (( NAME_BYTES > 255 )); then
    show_alert "$(t filename_too_long)" "warning"
    exit 0
fi


# =============================================================================
# Never overwrite an existing restored file
# =============================================================================

if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then

    show_alert \
        "$(tf destination_exists "$RESTORED_NAME")"

    exit 0
fi


# =============================================================================
# Safe restore procedure
#
# 1. Create an exclusive temporary file in the restore directory.
# 2. Copy the selected snapshot version into it.
# 3. Optionally compare the local copy byte-for-byte against the snapshot.
# 4. Move it to its final filename without overwriting anything.
#
# The original network file is never modified.
# =============================================================================

RESTORE_TEMP=$(
    /usr/bin/mktemp \
        "$RESTORE_DIR/.zfs-previous-versions.XXXXXX"
)


if [[ -z "$RESTORE_TEMP" || ! -f "$RESTORE_TEMP" ]]; then
    show_alert "$(t temp_failed)" "warning"
    exit 0
fi


# Copy while preserving timestamps and other supported metadata.
if ! /bin/cp -p "$SELECTED_FILE" "$RESTORE_TEMP"; then
    show_alert "$(t restore_failed)" "warning"
    exit 0
fi


# =============================================================================
# Optional byte-for-byte verification
#
# This provides maximum confidence that the local copy exactly matches the
# selected snapshot version.
#
# Be aware that verification causes the complete snapshot file to be read over
# SMB a second time. For very large files or slow remote connections this may
# therefore noticeably increase restore time.
# =============================================================================

if [[ "$VERIFY_RESTORE" == true ]]; then

    if ! /usr/bin/cmp -s "$SELECTED_FILE" "$RESTORE_TEMP"; then
        show_alert "$(t restore_failed)" "warning"
        exit 0
    fi

fi


# Move into place without overwriting a file that may have appeared after
# the previous existence check.
if ! /bin/mv -n "$RESTORE_TEMP" "$DESTINATION"; then
    show_alert "$(t restore_failed)" "warning"
    exit 0
fi


# BSD mv -n may leave the source untouched if the destination appeared in the
# meantime. Detect that case explicitly.
if [[ -e "$RESTORE_TEMP" ]]; then

    show_alert \
        "$(tf destination_exists "$RESTORED_NAME")"

    exit 0
fi


RESTORE_TEMP=""


# =============================================================================
# Final sanity check
# =============================================================================

if [[ ! -f "$DESTINATION" || -L "$DESTINATION" ]]; then
    show_alert "$(t restore_failed)" "warning"
    exit 0
fi


# =============================================================================
# Reveal the restored file in Finder
# =============================================================================

/usr/bin/osascript - \
    "$DESTINATION" <<'APPLESCRIPT'

on run argv

    set restoredFile to POSIX file (item 1 of argv)

    tell application "Finder"

        activate
        reveal restoredFile

    end tell

end run

APPLESCRIPT


exit 0
