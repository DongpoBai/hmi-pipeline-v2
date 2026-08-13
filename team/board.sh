#!/usr/bin/env bash
# ==============================================================================
# board.sh — team-mode collaboration layer for pipeline-v2
#
# Wraps the single-person wrappers (run_3day_mavg.sh / run_3day_fit.sh) with a
# task board: divide a Run's date ranges among people, hand each their tasks,
# collect their reports, show the board, and let people help each other.
#
# This layer runs OUTSIDE the container and does NOT source lib/common.sh.
# It never modifies the wrappers; it orchestrates them.
#
# Subcommands (see design ledger):
#   assign  mine  start  done  help  release  show  rebuild  why  set
#
# Usage: board.sh <subcommand> [args...]   (short alias: bd)
# ==============================================================================
set -uo pipefail

# ── Locate the pipeline root ────────────────────────────────────────────────
# board.sh lives in <pipeline>/team/, so PIPELINE_DIR is its parent's parent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${PIPELINE_DIR}/config"
TEAM_DIR="${SCRIPT_DIR}"

# Code and state live apart. board.sh and the science pages ship with the repo
# and are read-only to the group; boards, journal, configs and preferences are
# written by whoever runs a command, so they sit on group-writable storage.
# The override exists for testing and for moving the state elsewhere later. It
# is not something members need to set.
STATE_DIR="${BOARD_STATE_DIR:-/project2/erhodes_44/pipeline-v2-state}"

# Everything written under STATE_DIR has to be readable and writable by the
# rest of the group, and mktemp defaults to 0600. Without this the first person
# to write a board would be the only one able to read it afterwards.
umask 007
# The legacy pipeline tree, as seen from outside the container. Inside the
# container the same tree is /home/rcf-04/... and /auto/rcf-04/...
WMLTP_DIR="/project2/erhodes_44/rcf-04/astro10/wmltp/theor1.0"
ZC_DIR="${WMLTP_DIR}/hmi3dayall13zerocrossings"
F96_DIR="final96b2b4rev6wtdhpccdprr"

# ── team-layer paths ────────────────────────────────────────────────────────
CONFIGS_DIR="${STATE_DIR}/configs"       # per-member configs
BOARDS_DIR="${STATE_DIR}/boards"         # <part>_run<NN>.board snapshots
JOURNAL="${STATE_DIR}/journal.log"       # append-only history (primary)
JOURNAL_MIRROR="${STATE_DIR}/.mirror/journal.log"  # mirror on same group disk
CURRENT="${STATE_DIR}/current"           # current part->run declarations
PREFS_DIR="${STATE_DIR}/prefs"           # per-user display prefs
SCIENCE_DIR="${TEAM_DIR}/science"       # science snippets + why deep-dives

# ── Flags (parsed per-subcommand) ───────────────────────────────────────────
DRY_RUN=false

# ── Logging helpers (plain, no color dependency) ────────────────────────────
log()      { printf '%s\n' "$*"; }
log_err()  { printf 'ERROR: %s\n' "$*" >&2; }
log_dry()  { printf '[dry-run] %s\n' "$*"; }

die() { log_err "$*"; exit 1; }

# ── Color: only when stdout is an interactive terminal (else plain text) ─────
# Guards against ANSI escapes leaking into pipes / redirects / dumb terminals.
if [[ -t 1 ]]; then
    C_CMD=$'\033[36m'     # cyan: things you type (commands)
    C_GOAL=$'\033[32m'    # green: completion targets (done, the 1001s)
    C_DOING=$'\033[33m'   # yellow: in-progress (used by show)
    C_HELP=$'\033[35m'    # magenta: unclaimed / needs-help (used by show)
    C_PATH=$'\033[4m'     # underline: filesystem paths (no color, never clashes)
    C_DIFF=$'\033[1;33m'  # bold yellow: the one distinguishing letter (a/c)
    C_TERM=$'\033[94m'     # bright blue: a term being named for the first time
    C_RESET=$'\033[0m'
else
    C_CMD=''; C_GOAL=''; C_DOING=''; C_HELP=''; C_PATH=''; C_DIFF=''
    C_TERM=''; C_RESET=''
fi
cmd()  { printf '%s%s%s' "$C_CMD"  "$1" "$C_RESET"; }   # colorize a command
goal() { printf '%s%s%s' "$C_GOAL" "$1" "$C_RESET"; }   # colorize a target
path() { printf '%s%s%s' "$C_PATH" "$1" "$C_RESET"; }   # underline a path

# colorize a status word for the board display
status_color() {
    case "$1" in
        done)       printf '%sdone%s'       "$C_GOAL"  "$C_RESET" ;;
        running)    printf '%srunning%s'    "$C_DOING" "$C_RESET" ;;
        unassigned) printf '%sopen%s'       "$C_HELP"  "$C_RESET" ;;  # shown as "open"
        *)          printf '%s' "$1" ;;   # assigned -> default color, plain
    esac
}

# ── Read DATE_RANGES from a config WITHOUT sourcing it ───────────────────────
# Sourcing would leak the config's variables into our environment. Instead we
# extract just the DATE_RANGES=( ... ) block. Returns the ranges, one per line,
# on stdout. Whitespace and quotes stripped; comment/blank lines ignored.
read_date_ranges() {
    local conf="$1"
    [[ -f "$conf" ]] || { log_err "config not found: ${conf}"; return 1; }
    awk '
        /^[[:space:]]*DATE_RANGES=\(/ { inblock=1; next }
        inblock && /^[[:space:]]*\)/  { inblock=0; next }
        inblock {
            line=$0
            sub(/#.*/, "", line)                 # strip trailing comment
            gsub(/[[:space:]"'"'"']/, "", line)  # strip spaces and quotes
            if (line != "") print line
        }
    ' "$conf"
}

# ── Deterministic assignment: distribute N date ranges among M people ────────
# Rule (design ledger 4.2): the first few people (in given order) each take one
# extra when it does not divide evenly. Prints "name<TAB>idx" lines, idx 1-based
# into the date-range list, so the caller knows exactly who owns which range.
# Args: <total_ranges> <name1> <name2> ...
assign_ranges() {
    local total="$1"; shift
    local -a names=("$@")
    local nppl=${#names[@]}
    [[ $nppl -gt 0 ]] || { log_err "no names given"; return 1; }

    local base=$(( total / nppl ))
    local rem=$(( total % nppl ))

    local idx=1 p count
    for (( p=0; p<nppl; p++ )); do
        count=$base
        (( p < rem )) && count=$(( count + 1 ))   # first 'rem' people take one extra
        local c
        for (( c=0; c<count; c++ )); do
            printf '%s\t%d\n' "${names[$p]}" "$idx"
            idx=$(( idx + 1 ))
        done
    done
}

# ── caller identity default ─────────────────────────────────────────────────
whoami_default() { id -un; }

# ── resolve run: explicit arg wins; else read current for this part ──────────
# Prints the run number, or empty (caller checks) if neither available.
resolve_run() {
    local part="$1" explicit="${2:-}"
    if [[ -n "$explicit" ]]; then printf '%s\n' "$explicit"; return 0; fi
    [[ -f "$CURRENT" ]] || return 0
    awk -v p="$part" '$1==p {print $2; exit}' "$CURRENT"
}

# ── wrapper script name for a part ──────────────────────────────────────────
wrapper_for() {
    case "$1" in
        mavg) printf '%s\n' "run_3day_mavg.sh" ;;
        fit)  printf '%s\n' "run_3day_fit.sh" ;;
        *)    return 1 ;;
    esac
}

# ── completion criterion text for a part (what "done" looks like) ───────────
acceptance_for() {
    case "$1" in
        mavg) printf '%s\n' "1001 Y*aspc2nonavdisc and 1001 Y*cspc2nonavdisc files" ;;
        fit)  printf '%s\n' "8 H*errfp.gz and 0 H*failed.gz files" ;;
        *)    return 1 ;;
    esac
}

# ── run the wrapper's --validate for one member's config, parse per-DR result ─
# Delegates the completion judgment entirely to the wrapper (single source of
# truth for paths / globs / thresholds). Parses the wrapper's per-date-range
# lines and prints, for each: "<daterange> <OK|FAIL> <detail>".
# The wrapper prints lines like:
#   [3/6] 250920to0922: mavg=1000/1001 psdr=1001/1001 (MISMATCH)
#   [4/6] 250923to0925: mavg=1001 psdr=1001 (OK)
# We report OK/FAIL plus the raw mavg=.../psdr=... detail verbatim (no diagnosis).
# Args: <part> <run> <member_config>
validate_member() {
    local part="$1" run="$2" conf="$3"
    local wrapper; wrapper="$(wrapper_for "$part")"
    local wrapper_path="${PIPELINE_DIR}/${wrapper}"
    # Run the wrapper's validate mode; capture output. Do not fail on nonzero.
    local out
    # Reading the board is read-only, so it has to work for a member who has
    # not set LOG_DIR yet. The default is the shared install, which the group
    # cannot write, and the wrapper aborts before printing any counts.
    local bd_tmp="${TMPDIR:-/tmp}/bd-${USER}"
    mkdir -p "$bd_tmp" 2>/dev/null || true
    out="$(LOG_DIR="$bd_tmp" CHECKPOINT_DIR="$bd_tmp" \
        "$wrapper_path" --run "$run" --config "$conf" --validate 2>&1)" || true
    # Parse per-date-range lines. Be tolerant of the log prefix ([INFO]/[ERROR]).
    # Match the "<DR>: mavg=.../... psdr=.../..." pattern.
    printf '%s\n' "$out" | while IFS= read -r line; do
        # extract date range token (YYMMDDtoMMDD) followed by ": mavg="
        if [[ "$line" =~ ([0-9]{6}to[0-9]{4}):\ *(mavg=[^ ]*\ *psdr=[^ ]*)\ *\((OK|MISMATCH)\) ]]; then
            local dr="${BASH_REMATCH[1]}"
            local detail="${BASH_REMATCH[2]}"
            local verdict="${BASH_REMATCH[3]}"
            if [[ "$verdict" == "OK" ]]; then
                printf '%s OK %s\n' "$dr" "$detail"
            else
                printf '%s FAIL %s\n' "$dr" "$detail"
            fi
        fi
    done
}

# ── run the wrapper's --validate once for the whole run, parse every DR ──────
# validate_member runs the wrapper once per person. This runs it once against
# the run's main config, which already covers every date range on the board, so
# a full board costs one wrapper call instead of one per member.
#
# Prints "<daterange> <OK|FAIL>" per line on stdout. Prints nothing when the
# wrapper or the run config is missing, or when no line could be parsed. The
# caller treats empty output as "live status unavailable" and falls back to what
# the board records.
#
# The two wrappers word their verdicts differently, so each gets its own
# pattern rather than one shared regex:
#   mavg: [3/6] 250920to0922: mavg=1001 psdr=1001 (OK)
#   fit:  [OK] 250920to0922: 8 errfp.gz, 0 failed
# Args: <part> <run>
validate_all() {
    local part="$1" run="$2"
    local wrapper
    wrapper="$(wrapper_for "$part")" || return 0
    local wrapper_path="${PIPELINE_DIR}/${wrapper}"
    local conf="${CONFIG_DIR}/run${run}.conf"
    if [[ ! -f "$wrapper_path" || ! -f "$conf" ]]; then
        return 0
    fi

    local out
    # Reading the board is read-only, so it has to work for a member who has
    # not set LOG_DIR yet. The default is the shared install, which the group
    # cannot write, and the wrapper aborts before printing any counts.
    local bd_tmp="${TMPDIR:-/tmp}/bd-${USER}"
    mkdir -p "$bd_tmp" 2>/dev/null || true
    out="$(LOG_DIR="$bd_tmp" CHECKPOINT_DIR="$bd_tmp" \
        "$wrapper_path" --run "$run" --config "$conf" --validate 2>&1)" || true

    printf '%s\n' "$out" | while IFS= read -r line; do
        case "$part" in
            mavg)
                if [[ "$line" =~ ([0-9]{6}to[0-9]{4}):[[:space:]]*mavg=.*\((OK|MISMATCH)\) ]]; then
                    if [[ "${BASH_REMATCH[2]}" == "OK" ]]; then
                        printf '%s OK\n' "${BASH_REMATCH[1]}"
                    else
                        printf '%s FAIL\n' "${BASH_REMATCH[1]}"
                    fi
                fi
                ;;
            fit)
                if [[ "$line" =~ \[(OK|FAIL)\][[:space:]]*([0-9]{6}to[0-9]{4}): ]]; then
                    printf '%s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
                fi
                ;;
        esac
    done
}

# ── has this run finished Part 6 (regression, transpose, zero crossings)? ────
# Part 6 consumes the pairwise differences from Part 4, which in turn need every
# date range in the run to have been fitted. So the presence of the zero
# crossing output is proof that Part 3 finished for the whole run, and it stays
# true afterwards, unlike the *.errfp.gz files that Part 4 consumes and removes.
#
# 13 files, one per variable: nu and B in diffs and rats, wi/amp/pow in diffs,
# rats and rat2. Anything short of 13 is treated as not finished.
# Args: <run>   Returns 0 when complete.
zc_complete() {
    local run="$1"
    local n
    n="$(ls "${ZC_DIR}/zero_crossing.hmirun${run}rev6newrr."*".asym.out" 2>/dev/null | wc -l)"
    [[ "$n" -eq 13 ]]
}

# ── working days elapsed between two dates, weekends not counted ────────────
# Counts whole days after the start date up to and including the end date, so
# a card handed out on Friday has crossed one working day by Monday. Weekends
# are skipped because the threshold is tied to how often the group meets, and
# it does not meet on a weekend.
# Args: <YYYY-MM-DD start> [YYYY-MM-DD end]   end defaults to today.
working_days_since() {
    local start="$1"
    local end="${2:-$(date +%Y-%m-%d)}"
    local cur n=0 dow

    cur="$(date -d "$start + 1 day" +%Y-%m-%d 2>/dev/null)" || { printf '0\n'; return 0; }
    while [[ ! "$cur" > "$end" ]]; do
        dow="$(date -d "$cur" +%u)"        # 1 Mon .. 7 Sun
        (( dow <= 5 )) && n=$(( n + 1 ))
        cur="$(date -d "$cur + 1 day" +%Y-%m-%d)"
    done
    printf '%s\n' "$n"
}

# ── has this run already moved past the part in question? ───────────────────
# Intermediate products do not survive the pipeline. Part 4 consumes the
# gzipped fit output; the m-averaged spectra are cleared once they have been
# fitted. So an empty output directory means "not done yet" only while the run
# is still near that stage. Further along it means the opposite.
#
# This looks downstream instead. Each check below can only be true if every
# date range cleared both Part 2 and Part 3, so any one of them settles the
# whole run and no per-card counting is needed.
#
#   Part 6  the 13 zero crossing files
#   Part 4  276 binl files in a variable directory
#   Part 3  the merged 0001to1000.errfp in every date range
#
# Args: <run>   Returns 0 when the run has moved past Parts 2 and 3.
part_superseded() {
    local run="$1"
    local conf="${CONFIG_DIR}/run${run}.conf"

    zc_complete "$run" && return 0

    local mdidn=""
    [[ -f "$conf" ]] && mdidn="$(grep -E '^MDIDN=' "$conf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"

    if [[ -n "$mdidn" ]]; then
        local vardir
        vardir="$(ls -d "${WMLTP_DIR}"/*_hmi"${mdidn}" 2>/dev/null | head -1)"
        if [[ -n "$vardir" && -d "${vardir}/${F96_DIR}" ]]; then
            local nbinl
            nbinl="$(find "${vardir}/${F96_DIR}" -maxdepth 1 -name '*.binl' 2>/dev/null | wc -l)"
            [[ "$nbinl" -eq 276 ]] && return 0
        fi
    fi

    # Date ranges do not identify a run on their own: a rerun covers the same
    # dates as the run it replaces, and would inherit its merged fit output.
    # Requiring the run config keeps this check tied to a run that exists.
    [[ -f "$conf" ]] || return 1

    local board="${BOARDS_DIR}/mavg_run${run}.board"
    [[ -f "$board" ]] || return 1
    local dr nmerged=0 ntotal=0
    while read -r dr; do
        [[ -n "$dr" ]] || continue
        ntotal=$(( ntotal + 1 ))
        if find "${WMLTP_DIR}/weightedhmi${dr}dpirlnewrr" \
                -name '*.0001to1000.errfp' 2>/dev/null | grep -q .; then
            nmerged=$(( nmerged + 1 ))
        fi
    done < <(board_rows "$board" | awk '{print $2}')
    [[ "$ntotal" -gt 0 && "$nmerged" -eq "$ntotal" ]]
}

# ── how many working days a card may sit with no output ─────────────────────
# Read from team/cadence. The file holds a standing number and, above it, any
# number of "until YYYY-MM-DD <n>" overrides. The first override whose date has
# not yet passed wins; otherwise the standing number does. Dates compare as
# plain strings because the format is fixed and sorts correctly that way.
# Args: [YYYY-MM-DD]   defaults to today; the argument exists so this can be
#                      checked against dates other than the present one.
cadence_days() {
    local today="${1:-$(date +%Y-%m-%d)}"
    local f="${STATE_DIR}/cadence"
    local standing=5 pick=""

    if [[ -f "$f" ]]; then
        local a b c
        while read -r a b c _; do
            [[ -z "$a" || "${a:0:1}" == "#" ]] && continue
            if [[ "$a" == "until" ]]; then
                [[ "$b" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
                [[ "$c" =~ ^[0-9]+$ ]] || continue
                if [[ -z "$pick" && ! "$today" > "$b" ]]; then
                    pick="$c"
                fi
            elif [[ "$a" =~ ^[0-9]+$ ]]; then
                standing="$a"
            fi
        done < "$f"
    fi

    printf '%s\n' "${pick:-$standing}"
}

# ── read a data row's fields from a board (ignores # comment/header lines) ──
# Prints: idx daterange owner status completed_by timestamp  (tab-free, space sep)
board_rows() {
    local board="$1"
    grep -v '^[[:space:]]*#' "$board" 2>/dev/null | sed '/^[[:space:]]*$/d'
}

# ── rewrite a board, applying field updates to specific cards ───────────────
# Reads the board, for each data row whose idx is in the update set, replaces
# owner/status/completed_by/timestamp with the new values; keeps comments and
# other rows verbatim; writes back atomically. Updates are passed via a global
# associative array UPD_<field> keyed by idx (set by the caller). This keeps the
# awk-free logic simple and robust.
# Args: <board_file>   (caller fills UPD_STATUS/UPD_OWNER/UPD_CBY/UPD_TS assoc arrays)
board_rewrite() {
    local board="$1"
    local tmp; tmp="$(mktemp "$(dirname "$board")/.tmp.XXXXXX")"
    chmod 660 "$tmp" 2>/dev/null || true
    local line idx dr owner status cby ts rest
    while IFS= read -r line; do
        # keep comments and blank lines verbatim
        if [[ "$line" =~ ^[[:space:]]*# || -z "${line//[[:space:]]/}" ]]; then
            printf '%s\n' "$line" >> "$tmp"; continue
        fi
        # timestamp is multi-word (date time TZ), so capture cols 1-5 then the rest as ts
        read -r idx dr owner status cby ts <<< "$line"
        # ts here holds the remainder (date time TZ) or '-'
        if [[ -n "${UPD_STATUS[$idx]:-}" || -n "${UPD_OWNER[$idx]:-}" || -n "${UPD_CBY[$idx]:-}" || -n "${UPD_TS[$idx]:-}" ]]; then
            owner="${UPD_OWNER[$idx]:-$owner}"
            status="${UPD_STATUS[$idx]:-$status}"
            cby="${UPD_CBY[$idx]:-$cby}"
            ts="${UPD_TS[$idx]:-$ts}"
        fi
        printf '  %s  %s  %s  %s  %s  %s\n' "$idx" "$dr" "$owner" "$status" "$cby" "$ts" >> "$tmp"
    done < "$board"
    mv -f "$tmp" "$board"
}

# ── display preference for a user (full|brief|off), default full ────────────
science_pref() {
    local who="${1:-}"
    local f="${PREFS_DIR}/${who}"
    if [[ -f "$f" ]]; then
        local v; v="$(grep -E '^science ' "$f" 2>/dev/null | awk '{print $2}' | tail -1)"
        [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
    fi
    printf 'full\n'   # default
}

# ── print the science snippet for a part (respects pref) ────────────────────
print_science_snippet() {
    local part="$1" who="$2"
    local pref; pref="$(science_pref "$who")"
    case "$pref" in
        off)   return 0 ;;
        brief) log ""; printf '(%s for the science)\n' "$(cmd "bd why ${part}")"; return 0 ;;
    esac
    # full
    local snip="${SCIENCE_DIR}/${part}.snippet.mine"
    if [[ -f "$snip" ]]; then
        log ""
        cat "$snip"
        log ""
        printf 'Curious how it works? %s\n' "$(cmd "bd why ${part}")"
    fi
}

# ── timestamp: local time with timezone (YYYY-MM-DD HH:MM:SS TZ) ─────────────
now_ts() { date '+%Y-%m-%d %H:%M:%S %Z'; }

# ── atomic write: write stdin to a temp file, then mv over target ────────────
# Guards against half-written/corrupt files if interrupted mid-write.
atomic_write() {
    local target="$1"
    local dir; dir="$(dirname "$target")"
    mkdir -p "$dir"
    local tmp; tmp="$(mktemp "${dir}/.tmp.XXXXXX")"
    chmod 660 "$tmp" 2>/dev/null || true
    cat > "$tmp"
    mv -f "$tmp" "$target"
}

# ── journal: append one line to primary + mirror (both on group disk) ────────
# append-only, each line self-contained (survives truncation: only the tail is
# lost). Never fails the caller's main action; a mirror-write failure is noted
# but not fatal.
journal_append() {
    local line="$1"
    mkdir -p "$(dirname "$JOURNAL")" "$(dirname "$JOURNAL_MIRROR")"
    printf '%s\n' "$line" >> "$JOURNAL"
    printf '%s\n' "$line" >> "$JOURNAL_MIRROR" 2>/dev/null || \
        log_err "warning: journal mirror write failed (primary ok): ${JOURNAL_MIRROR}"
}

# ── generate a per-member config from the master config ─────────────────────
# Copies the master verbatim, but replaces the DATE_RANGES=( ... ) block (and
# the contiguous comment "hat" immediately above it) with this member's ranges.
# Validates the result with bash -n. Args:
#   <master_conf> <out_conf> <name> <run> <part> <range...>
gen_member_config() {
    local master="$1" out="$2" name="$3" run="$4" part="$5"; shift 5
    local -a ranges=("$@")

    local newblock
    newblock="# Date ranges assigned to ${name} for Run ${run} ${part} (${#ranges[@]} ranges)"$'\n'
    newblock+="DATE_RANGES=("$'\n'
    local r
    for r in "${ranges[@]}"; do
        newblock+="    \"${r}\""$'\n'
    done
    newblock+=")"

    mkdir -p "$(dirname "$out")"
    local tmp; tmp="$(mktemp "$(dirname "$out")/.tmp.XXXXXX")"
    chmod 660 "$tmp" 2>/dev/null || true
    awk -v newblock="$newblock" '
        function flush_buf(   i) { for (i=1;i<=bn;i++) print buf[i]; bn=0 }
        BEGIN { bn=0; inblock=0 }
        {
            if (inblock) { if ($0 ~ /^[[:space:]]*\)/) inblock=0; next }
            if ($0 ~ /^[[:space:]]*DATE_RANGES=\(/) {
                # drop buffered comment hat; keep exactly one blank line before block
                bn=0
                print ""
                print newblock
                inblock=1
                next
            }
            if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) { buf[++bn]=$0; next }
            flush_buf(); print $0
        }
        END { flush_buf() }
    ' "$master" > "$tmp"

    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        log_err "generated config failed syntax check for ${name}: ${out}"
        return 1
    fi
    mv -f "$tmp" "$out"
}

# ============================================================================
# SUBCOMMAND: assign  (this block: DRY-RUN PREVIEW ONLY — writes nothing yet)
# ============================================================================
cmd_assign() {
    local part="" run="" fresh=false ; local -a names=()
    # positional: <part> <run> <names...>, plus --dry-run --fresh
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            --fresh)   fresh=true; shift ;;
            --*)       die "unknown flag for assign: $1" ;;
            *)
                if [[ -z "$part" ]]; then part="$1"
                elif [[ -z "$run" ]]; then run="$1"
                else names+=("$1"); fi
                shift ;;
        esac
    done

    [[ -n "$part" ]] || die "assign: missing <part> (mavg|fit)"
    [[ -n "$run"  ]] || die "assign: missing <run>"
    [[ "$part" == "mavg" || "$part" == "fit" ]] || die "assign: part must be mavg or fit, got '${part}'"
    [[ ${#names[@]} -gt 0 ]] || die "assign: give at least one member name"

    local board_file="${BOARDS_DIR}/${part}_run${run}.board"

    # Board already exists: refuse by default (guards against accidental
    # overwrite of in-progress work). --fresh means "tear down and rebuild",
    # which backs up the old board first. (Incremental re-assign that preserves
    # done cards is a separate command, coming later.)
    if [[ -f "$board_file" && "$fresh" != "true" && "$DRY_RUN" != "true" ]]; then
        die "assign: board already exists: ${board_file}
  To rebuild from scratch (backs up the old one): add --fresh
  To edit by hand: the board is plain text.
  (Incremental re-assign preserving done cards is a separate command, coming later.)"
    fi

    local conf="${CONFIG_DIR}/run${run}.conf"

    # Load date ranges. Honest dry-run: if the config's DATE_RANGES is empty
    # (brand-new run not yet filled), preview with placeholders instead of
    # crashing, mirroring the wrapper's own dry-run behavior.
    local -a ranges=()
    if [[ -f "$conf" ]]; then
        mapfile -t ranges < <(read_date_ranges "$conf")
    fi
    if [[ ${#ranges[@]} -eq 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "config ${conf} has no DATE_RANGES filled; previewing with placeholders"
            local i
            for i in $(seq -w 1 24); do ranges+=("DR_PLACEHOLDER_${i}"); done
        else
            die "assign: no DATE_RANGES in ${conf} (fill config or verify genDRlist ran)"
        fi
    fi

    local total=${#ranges[@]}

    # Compute the assignment.
    local -a assignment=()
    mapfile -t assignment < <(assign_ranges "$total" "${names[@]}")

    # ── Preview (dry-run) or, later, real write ──
    log "Run ${run} ${part}: dividing ${total} date ranges among ${#names[@]} people"
    log ""

    # Group by owner for the "dealing has ceremony" line.
    local name
    for name in "${names[@]}"; do
        local -a mine_idx=()
        local row
        while IFS=$'\t' read -r rowname rowidx; do
            [[ "$rowname" == "$name" ]] && mine_idx+=("$rowidx")
        done <<< "$(printf '%s\n' "${assignment[@]}")"
        local first="${mine_idx[0]}" last="${mine_idx[-1]}"
        printf '  %s takes %d ranges (%02d-%02d):\n' "$name" "${#mine_idx[@]}" "$first" "$last"
        # list the actual date ranges, 3 per line, indented
        local col=0 j
        printf '     '
        for j in "${mine_idx[@]}"; do
            printf ' %s' "${ranges[$((j-1))]}"
            col=$(( col + 1 ))
            if (( col % 3 == 0 && col < ${#mine_idx[@]} )); then printf '\n     '; fi
        done
        printf '\n'
    done
    log ""

    if [[ "$DRY_RUN" == "true" ]]; then
        [[ -f "$board_file" ]] && log_dry "board exists; would ${fresh:+--fresh }back up and rebuild"
        log_dry "would create board:   ${board_file}"
        log_dry "would create configs: ${CONFIGS_DIR}/${part}_run${run}_<name>.conf  (one per member)"
        log_dry "would set current:    ${part} -> ${run}  in ${CURRENT}"
        log_dry "would append journal: assign event  (+ mirror)"
        log_dry "no files written."
        return 0
    fi

    # ── Real write ──

    # If --fresh and a board exists, back it up first.
    if [[ -f "$board_file" && "$fresh" == "true" ]]; then
        local bak="${board_file}.bak_$(date +%Y%m%d_%H%M%S)"
        cp -p "$board_file" "$bak"
        log "backed up existing board -> $(path "${bak}")"
    fi

    # 1) per-member configs (skip if placeholders; only real ranges make sense)
    if [[ "${ranges[0]}" == DR_PLACEHOLDER_* ]]; then
        die "assign: refusing real write with placeholder ranges (config ${conf} has no DATE_RANGES)"
    fi
    local name
    for name in "${names[@]}"; do
        local -a member_ranges=()
        local rowname rowidx
        while IFS=$'\t' read -r rowname rowidx; do
            [[ "$rowname" == "$name" ]] && member_ranges+=("${ranges[$((rowidx-1))]}")
        done <<< "$(printf '%s\n' "${assignment[@]}")"
        local member_conf="${CONFIGS_DIR}/${part}_run${run}_${name}.conf"
        gen_member_config "$conf" "$member_conf" "$name" "$run" "$part" "${member_ranges[@]}" \
            || die "assign: failed to generate config for ${name}"
    done

    # 2) board snapshot
    {
        printf '# team board  |  part=%s  run=%s  |  generated %s\n' "$part" "$run" "$(now_ts)"
        printf '# columns: idx  daterange  owner  status  completed_by  timestamp\n'
        printf '# status: unassigned | assigned   (completion is counted from the outputs, never written here)\n'
        local rowname rowidx
        # build idx->owner map from assignment
        declare -A owner_of=()
        while IFS=$'\t' read -r rowname rowidx; do
            owner_of[$rowidx]="$rowname"
        done <<< "$(printf '%s\n' "${assignment[@]}")"
        local i
        for (( i=1; i<=total; i++ )); do
            printf '  %02d  %s  %s  %s  %s  %s\n' \
                "$i" "${ranges[$((i-1))]}" "${owner_of[$i]}" "assigned" "-" "-"
        done
    } | atomic_write "$board_file"

    # 3) current: update this part's line, keep others
    {
        if [[ -f "$CURRENT" ]]; then grep -v "^${part} " "$CURRENT" 2>/dev/null || true; fi
        printf '%s %s\n' "$part" "$run"
    } | atomic_write "$CURRENT"

    # 4) journal (primary + mirror)
    local members_csv; members_csv="$(IFS=,; echo "${names[*]}")"
    journal_append "$(now_ts)  ${part}  ${run}  event=assign  by=$(whoami_default)  members=${members_csv}"

    log "board created: $(path "${board_file}")"
    log "per-member configs in: $(path "${CONFIGS_DIR}/")"
    log "each member: $(cmd "bd ${part}")"
}

# ── print the full command sequence for one card ────────────────────────────
# Everything is spelled out with the date range already filled in, so a member
# copies and pastes and never edits a command by hand. Editing a date range by
# hand is exactly where a wrong range slips in.
# Args: <part> <run> <idx> <daterange> <live_verdict>
print_card() {
    local part="$1" run="$2" idx="$3" dr="$4" live="$5"
    local cont_dir="/home/rcf-57/astro0/data/avgspc2880.wtnonavgcorrall.${dr}dpirlnewrr.hpcc"
    local host_dir="/project2/erhodes_44/rcf-57/astro0/data/avgspc2880.wtnonavgcorrall.${dr}dpirlnewrr.hpcc"
    local fit_dir="/project2/erhodes_44/rcf-04/astro10/wmltp/theor1.0/weightedhmi${dr}dpirlnewrr/fdxref61/lgcfnonncorall96b2b4rev6asm"

    log ""
    printf '%s\n' "────────────────────────────────────────────────────────"
    if [[ "$live" == "OK" ]]; then
        printf 'Card %s, %s.  %s\n' "$idx" "$dr" "$(goal 'This one is already finished.')"
        log "Left here in case you want to see what it took."
    else
        printf 'Card %s, %s.\n' "$idx" "$dr"
    fi

    case "$part" in
      mavg)
        log ""
        log "Step 1, inside the container. This brings in the l=0 spectrum, which"
        log "the m-averaging needs and which no other step produces."
        log ""
        printf '  %s\n' "$(cmd 'sing')"
        printf '  %s\n' "$(cmd 'export PREPATH=/home')"
        printf '  %s\n' "$(cmd "cd $(path "$cont_dir")")"
        printf '  %s\n' "$(cmd './cp000file.sh')"
        printf '  %s\n' "$(cmd 'exit')"
        log ""
        log "The export line is easy to skip past, so it is worth a word. Inside the"
        log "container cp000file.sh looks for \$PREPATH/rcf-93/..., and that tree only"
        printf 'exists under /home. Without it the copy quietly does nothing and the\n'
        printf 'count in step 2 lands on %s rather than %s.\n' "$(goal '1000')" "$(goal '1001')"
        log ""
        log "Step 2, back on Discovery. M-averaging, roughly 15 minutes."
        log ""
        printf '  %s\n' "$(cmd "cd $(path "$host_dir")")"
        printf '  %s\n' "$(cmd "sbatch sbatchmavg${dr}.slurm")"
        printf '  %s\n' "$(cmd 'squeue -u $USER')"
        printf '  %s  %s\n' "$(cmd "ls Y*${C_DIFF}a${C_RESET}${C_CMD}spc2nonavdisc | wc -l")" "-> $(goal '1001')"
        log ""
        log "The job sits in the queue a while before it computes anything, so a count"
        log "of 0 while squeue still lists it is just the queue doing its thing. Once"
        log "squeue comes back empty the count means something."
        log ""
        log "Step 3, same directory. Renormalization, a couple of minutes."
        log ""
        printf '  %s\n' "$(cmd "sbatch sbatchpsdrenorm${dr}.slurm")"
        printf '  %s\n' "$(cmd 'squeue -u $USER')"
        printf '  %s  %s\n' "$(cmd "ls Y*${C_DIFF}c${C_RESET}${C_CMD}spc2nonavdisc | wc -l")" "-> $(goal '1001')"
        log ""
        printf 'Both counts at %s and this card is done.\n' "$(goal '1001')"
        ;;
      fit)
        log ""
        log "This one runs outside the container, so leave it first if you are in."
        log ""
        printf '  %s\n' "$(cmd 'exit')"
        printf '  %s\n' "$(cmd "cd $(path "$fit_dir")")"
        printf '  %s\n' "$(cmd "./qsubfitjob${dr}dpirlnewrr.rev6.slurm.sh 0 0")"
        printf '  %s\n' "$(cmd 'squeue -u $USER')"
        log ""
        log "This is the long one. Anywhere under 12 hours is normal, so start it and"
        log "go do something else."
        log ""
        log "Once squeue stops listing it:"
        log ""
        printf '  %s\n' "$(cmd 'cd D')"
        printf '  %s  %s\n' "$(cmd 'ls H*errfp.gz | wc -l')"  "-> $(goal '8')"
        printf '  %s  %s\n' "$(cmd 'ls H*failed.gz | wc -l')" "-> $(goal '0')"
        log ""
        log "The 8 are l ranges: 0001to0015, 0016to0030, 0031to0060, 0061to0100,"
        log "0101to0149, 0150to0200, 0201to0600, 0601to1000."
        log ""
        log "A H*failed.gz means a mode would not converge, which happens and is not"
        log "something you did. Bring it to your lead and it gets a new seed."
        ;;
    esac
}

# ============================================================================
# SUBCOMMAND: mavg | fit  (read-only: your own cards and how to run them)
# ============================================================================
# Invoked as "bd mavg" or "bd fit", so a member types the part they were given
# and nothing else. A bare number selects one card; the run comes from the
# current file unless --run says otherwise.
cmd_cards() {
    local part="$1"; shift || true
    local run="" want_idx=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run) run="${2:-}"; shift 2 || die "${part}: --run needs a run number" ;;
            --*)   die "unknown flag for ${part}: $1" ;;
            *)
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    [[ -z "$want_idx" ]] || die "${part}: give at most one card number"
                    want_idx="$(printf '%02d' "$((10#$1))")"
                else
                    die "${part}: expected a card number, got '$1'. To see the whole board use: bd show ${part}"
                fi
                shift ;;
        esac
    done

    run="$(resolve_run "$part" "$run")"
    [[ -n "$run" ]] || die "${part}: no current run set. Ask your lead to run 'bd assign ${part} <run> ...', or name it: bd ${part} --run <run>"

    local board="${BOARDS_DIR}/${part}_run${run}.board"
    [[ -f "$board" ]] || die "${part}: no board for run ${run} (${board}). Has it been assigned yet?"

    local me; me="$(whoami_default)"

    # My cards, in board order.
    local -a my_idx=() my_dr=() my_cby=()
    local idx dr owner status cby ts rest
    while read -r idx dr owner status cby ts rest; do
        [[ "$owner" == "$me" ]] || continue
        my_idx+=("$idx"); my_dr+=("$dr"); my_cby+=("$cby")
    done < <(board_rows "$board")

    if [[ ${#my_idx[@]} -eq 0 ]]; then
        log "You have no cards on the ${part} run ${run} board."
        log "Everyone's assignments are visible with: $(cmd "bd show ${part} ${run}")"
        return 0
    fi

    # Live completion, counted from the outputs (same source as bd show).
    declare -A LIVE=()
    local live_n=0 lv_dr lv_verdict lv_count
    while read -r lv_dr lv_verdict lv_count; do
        if [[ -n "$lv_dr" ]]; then
            LIVE["$lv_dr"]="$lv_verdict"
            live_n=$(( live_n + 1 ))
        fi
    done < <(validate_all "$part" "$run")

    # The intermediate outputs are gone once the run moves downstream, so
    # counting them would say none of your cards are done when in fact all of
    # them are. bd show settles this the same way, and the two must not
    # disagree: one saying finished while the other says untouched is worse
    # than either being wrong alone.
    if part_superseded "$run"; then
        local sd_i
        for (( sd_i=0; sd_i<${#my_dr[@]}; sd_i++ )); do
            LIVE["${my_dr[$sd_i]}"]="OK"
        done
        live_n=${#my_dr[@]}
    fi

    local n=${#my_idx[@]}
    local i found=0 n_done=0

    for (( i=0; i<n; i++ )); do
        [[ "${LIVE[${my_dr[$i]}]:-}" == "OK" ]] && n_done=$(( n_done + 1 ))
    done

    # ── one card ──
    if [[ -n "$want_idx" ]]; then
        for (( i=0; i<n; i++ )); do
            [[ "${my_idx[$i]}" == "$want_idx" ]] || continue
            found=1
            print_card "$part" "$run" "${my_idx[$i]}" "${my_dr[$i]}" "${LIVE[${my_dr[$i]}]:-}"
        done
        if [[ $found -eq 0 ]]; then
            log "Card ${want_idx} is not one of yours on the ${part} run ${run} board."
            log "Yours are: ${my_idx[*]}"
            log "The whole board: $(cmd "bd show ${part} ${run}")"
        fi
        return 0
    fi

    # ── all my cards ──
    printf 'Run %s %s. %d date ranges are yours, %s finished.\n' \
        "$run" "$part" "$n" "$(goal "${n_done}")"
    if [[ $live_n -eq 0 ]]; then
        log "(live counts unavailable, so the finished tally may be stale)"
    fi
    log ""
    for (( i=0; i<n; i++ )); do
        if [[ "${LIVE[${my_dr[$i]}]:-}" == "OK" ]]; then
            printf '  %s  %s  %s\n' "${my_idx[$i]}" "${my_dr[$i]}" "$(goal 'done')"
        else
            printf '  %s  %s\n' "${my_idx[$i]}" "${my_dr[$i]}"
        fi
    done
    log ""
    log "Do them one at a time. The commands for a single card:"
    printf '  %s\n' "$(cmd "bd ${part} ${my_idx[0]}")"
    log ""
    log "Full commands for every card follow. Nothing needs editing: the date"
    log "ranges are already filled in, so copy and paste."

    for (( i=0; i<n; i++ )); do
        print_card "$part" "$run" "${my_idx[$i]}" "${my_dr[$i]}" "${LIVE[${my_dr[$i]}]:-}"
    done

    log ""
    printf '%s\n' "────────────────────────────────────────────────────────"
    log ""
    log "There is nothing to report when a card is finished."
    printf '%s counts the files itself and turns the card %s.\n' \
        "$(cmd "bd show ${part} ${run}")" "$(goal 'green')"

    # Cards finished by someone other than you. The board no longer records who
    # did it, so this says that the work is there, not who did it.
    local h=0
    for (( i=0; i<n; i++ )); do
        if [[ "${LIVE[${my_dr[$i]}]:-}" == "OK" && "${my_cby[$i]}" != "-" && "${my_cby[$i]}" != "$me" ]]; then
            [[ $h -eq 0 ]] && log ""
            h=1
            printf '  %s got %s (%s) for you.\n' "${my_cby[$i]}" "${my_idx[$i]}" "${my_dr[$i]}"
        fi
    done

    print_science_snippet "$part" "$me"
}

# ============================================================================
# SUBCOMMAND: show  (read-only: the whole board, grouped by person)
# ============================================================================
cmd_show() {
    local part="" run="" filter_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --*) die "unknown flag for show: $1" ;;
            *)
                if [[ -z "$part" ]]; then part="$1"
                elif [[ -z "$run" && "$1" =~ ^[0-9]+$ ]]; then run="$1"
                elif [[ -z "$filter_name" ]]; then filter_name="$1"
                else die "show: too many arguments"; fi
                shift ;;
        esac
    done

    [[ -n "$part" ]] || die "show: missing <part> (mavg|fit)"
    [[ "$part" == "mavg" || "$part" == "fit" ]] || die "show: part must be mavg or fit, got '${part}'"

    run="$(resolve_run "$part" "$run")"
    [[ -n "$run" ]] || die "show: no current ${part} run set. Run 'bd assign ${part} <run> ...' first, or name the run: bd show ${part} <run>"

    local board="${BOARDS_DIR}/${part}_run${run}.board"
    [[ -f "$board" ]] || die "show: no board for ${part} run ${run} (${board})."

    # Read all rows into parallel arrays.
    local -a r_idx=() r_dr=() r_owner=() r_status=() r_cby=()
    local idx dr owner status cby ts rest
    local -a owner_order=()   # owners in first-seen order
    declare -A seen_owner=()
    local total=0
    while read -r idx dr owner status cby ts rest; do
        r_idx+=("$idx"); r_dr+=("$dr"); r_owner+=("$owner")
        r_status+=("$status"); r_cby+=("$cby")
        total=$(( total + 1 ))
        # track owner order (skip the placeholder '-' for open cards)
        if [[ "$owner" != "-" && -z "${seen_owner[$owner]:-}" ]]; then
            seen_owner[$owner]=1
            owner_order+=("$owner")
        fi
    done < <(board_rows "$board")

    [[ $total -gt 0 ]] || die "show: board has no cards: ${board}"

    # ── live completion, counted rather than declared ────────────────────────
    # The board records who owns which card. Whether a card is finished is not
    # recorded there: it is counted from the outputs every time show runs, by
    # asking the wrapper. A card whose outputs are complete therefore reads as
    # done without anyone having written that into the board.
    declare -A LIVE=()
    local live_n=0 lv_dr lv_verdict lv_count
    while read -r lv_dr lv_verdict lv_count; do
        if [[ -n "$lv_dr" ]]; then
            LIVE["$lv_dr"]="$lv_verdict"
            live_n=$(( live_n + 1 ))
        fi
    done < <(validate_all "$part" "$run")

    # Effective status per card. With live counts available: complete outputs
    # read as done, and a stale 'running' or 'done' left in an older board reads
    # as 'assigned', since nothing writes those states any more. Without live
    # counts the board is shown verbatim, so a wrapper problem degrades the
    # display instead of silently reporting everything as unfinished.
    # A run that has moved past this part is finished here even though the
    # intermediate outputs are gone: they were consumed downstream. Counting
    # files would report the whole board as untouched, which is the opposite of
    # the truth, so the downstream evidence settles it instead.
    local superseded=0
    part_superseded "$run" && superseded=1

    local -a r_eff=()
    local n_done=0 n_doing=0 n_assigned=0 n_open=0 i eff
    for (( i=0; i<total; i++ )); do
        eff="${r_status[$i]}"
        if [[ $superseded -eq 1 ]]; then
            eff="done"
        elif [[ $live_n -gt 0 ]]; then
            if [[ "$eff" == "running" || "$eff" == "done" ]]; then
                eff="assigned"
            fi
            if [[ "${r_owner[$i]}" == "-" ]]; then
                eff="unassigned"
            fi
            if [[ "${LIVE[${r_dr[$i]}]:-}" == "OK" ]]; then
                eff="done"
            fi
        fi
        r_eff+=("$eff")
        case "$eff" in
            done)       n_done=$(( n_done + 1 )) ;;
            running)    n_doing=$(( n_doing + 1 )) ;;
            assigned)   n_assigned=$(( n_assigned + 1 )) ;;
            unassigned) n_open=$(( n_open + 1 )) ;;
        esac
    done

    # ── header / overview line ──
    local overview="${n_done} done, ${n_assigned} to go"
    (( n_doing > 0 )) && overview="${n_done} done, ${n_doing} running, ${n_assigned} to go"
    (( n_open > 0 )) && overview+=", ${n_open} open"
    log "Run ${run} ${part}:  ${overview}  (${total} total)"
    if [[ $superseded -eq 1 ]]; then
        log "(this run has moved past ${part}; counted from what the later parts produced)"
    elif [[ $live_n -eq 0 ]]; then
        log "(live counts unavailable, showing what the board records)"
    fi

    # helper: print one person's cards + tally
    print_person() {
        local who="$1"
        local -a idxs=()
        local d=0 tot=0 i
        for (( i=0; i<total; i++ )); do
            [[ "${r_owner[$i]}" == "$who" ]] || continue
            idxs+=("$i"); tot=$(( tot + 1 ))
            [[ "${r_eff[$i]}" == "done" ]] && d=$(( d + 1 ))
        done
        [[ $tot -gt 0 ]] || return 0
        log ""
        printf '%s  (%d/%d done)\n' "$who" "$d" "$tot"
        for i in "${idxs[@]}"; do
            local extra=""
            if [[ "${r_eff[$i]}" == "done" && "${r_cby[$i]}" != "-" && "${r_cby[$i]}" != "$who" ]]; then
                extra="  (by ${r_cby[$i]})"
            fi
            printf '   %s  %s  %s%s\n' "${r_idx[$i]}" "${r_dr[$i]}" "$(status_color "${r_eff[$i]}")" "$extra"
        done
    }

    # ── if filtering to one person ──
    if [[ -n "$filter_name" ]]; then
        local found=0 o
        for o in "${owner_order[@]}"; do [[ "$o" == "$filter_name" ]] && found=1; done
        if [[ $found -eq 0 ]]; then
            log ""
            log "${filter_name} has no cards on this board."
            return 0
        fi
        print_person "$filter_name"
        return 0
    fi

    # ── grouped by person, in assignment order ──
    local o
    for o in "${owner_order[@]}"; do
        print_person "$o"
    done

    # ── open (unassigned) cards, only if any exist ──
    if (( n_open > 0 )); then
        log ""
        printf 'open  (%d)\n' "$n_open"
        local i
        for (( i=0; i<total; i++ )); do
            [[ "${r_eff[$i]}" == "unassigned" || "${r_owner[$i]}" == "-" ]] || continue
            printf '   %s  %s  %s\n' "${r_idx[$i]}" "${r_dr[$i]}" "$(status_color unassigned)"
        done
    fi
}



# ---- why: the science pages -------------------------------------------------
# Deliberately ignores the per-user science preference. That setting controls
# whether a snippet is volunteered; asking outright is a different thing, and
# someone who asks always gets an answer.
cmd_why() {
    local topic="${1:-}"
    shift || true
    [[ $# -eq 0 ]] || die "bd why takes at most one topic. Extra: $*"

    case "$topic" in
        "")        topic="ground" ;;
        mavg|fit)  ;;
        *)         die "bd why takes nothing, mavg, or fit. Got: ${topic}" ;;
    esac

    local page="${SCIENCE_DIR}/${topic}.why"
    if [[ ! -f "$page" ]]; then
        log_err "There's no ${topic} page here yet (looked for ${page})."
        return 1
    fi

    # A term gets emphasis the first time it appears and never again. The first
    # time is the sentence that names it; after that it is just a word, and
    # marking every instance would only add noise to the page.
    local terms="${SCIENCE_DIR}/terms.list"

    # Paging and the -t 1 color guard are mutually exclusive: once stdout is a
    # pipe into less, C_TERM is empty. So the escapes are written here and less
    # is told to render them with -R.
    if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then
        emphasize_terms "$page" "$terms" $'\033[94m' $'\033[0m' | less -FXR
    else
        emphasize_terms "$page" "$terms" "$C_TERM" "$C_RESET"
    fi
}

# Emphasize each listed term on its first appearance in a text file.
#   $1 page  $2 terms list  $3 on-sequence  $4 off-sequence
# Skips separator rules and URL lines so that terms occurring inside a link or
# a row of dashes are left alone. Matches an optional trailing s, and tries
# longer terms first so that a term containing another is not broken up.
emphasize_terms() {
    local page="$1" terms="$2" on="$3" off="$4"

    if [[ -z "$on" || ! -f "$terms" ]]; then
        cat "$page"
        return 0
    fi

    awk -v on="$on" -v off="$off" '
        NR == FNR {
            if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            term[++n] = $0
            tlen[n] = length($0)
            next
        }
        { text = text $0 "\n" }
        END {
            if (n == 0) { printf "%s", text; exit }

            P1 = sprintf("%c", 1); P2 = sprintf("%c", 2)

            # Lift URLs out first. A term inside a link is not a term being
            # named, and rewriting one would break the link.
            nurl = 0
            while (match(text, /https?:\/\/[^ \t\n]+/)) {
                urls[++nurl] = substr(text, RSTART, RLENGTH)
                text = substr(text, 1, RSTART - 1) P1 nurl P2 \
                       substr(text, RSTART + RLENGTH)
            }

            # Longest first, so a term containing another is not broken up.
            for (i = 1; i <= n; i++)
                for (j = i + 1; j <= n; j++)
                    if (tlen[j] > tlen[i]) {
                        t = term[i]; term[i] = term[j]; term[j] = t
                        l = tlen[i]; tlen[i] = tlen[j]; tlen[j] = l
                    }

            for (i = 1; i <= n; i++) mark(term[i])

            for (i = 1; i <= nurl; i++) {
                ph = P1 i P2
                p = index(text, ph)
                if (p > 0)
                    text = substr(text, 1, p - 1) urls[i] \
                           substr(text, p + length(ph))
            }
            printf "%s", text
        }

        # Emphasize the first real occurrence of one term, anywhere in the
        # whole text. The gap between words is matched as any run of
        # whitespace, so a term broken across a line wrap still counts.
        function mark(t,   pat, lo, from, ms, ml, before, after, ap, ch) {
            pat = tolower(t)
            gsub(/ /, "[[:space:]]+", pat)
            lo = tolower(text)
            from = 1
            while (match(substr(lo, from), pat)) {
                ms = from + RSTART - 1
                ml = RLENGTH
                before = (ms == 1) ? "" : substr(lo, ms - 1, 1)
                ap = ms + ml
                ch = 0
                if (substr(lo, ap, 1) == "s") { ch = 1; ap++ }
                after = substr(lo, ap, 1)
                if (before !~ /[a-z0-9-]/ && after !~ /[a-z0-9-]/) {
                    text = substr(text, 1, ms - 1) on \
                           substr(text, ms, ml + ch) off \
                           substr(text, ms + ml + ch)
                    return
                }
                from = ms + 1
            }
        }
    ' "$terms" "$page"
}

# ---- set: per-user display preferences ---------------------------------------
# Yours only. There is no way to set this for somebody else, and no group
# default beyond the built-in one, because how much explanation a person wants
# alongside their work is theirs to decide.
cmd_set() {
    [[ $# -le 2 ]] || die "bd set takes a key and a value. Extra: ${*:3}"
    local key="${1:-}" val="${2:-}"

    case "$key" in
        ""|science) ;;
        *) die "The only setting is science. Got: ${key}" ;;
    esac

    local me; me="$(whoami_default)"

    # No value: report where things stand rather than changing anything.
    if [[ -z "$val" ]]; then
        local cur; cur="$(science_pref "$me")"
        log "Science notes are currently: ${cur}"
        log ""
        log "  full    the whole explanation, every time (this is the default)"
        log "  brief   one line, with a pointer to $(cmd 'bd why')"
        log "  off     nothing"
        log ""
        log "Change it with $(cmd 'bd set science <choice>'). It applies to you only."
        log "$(cmd 'bd why') always answers in full, whatever this is set to."
        return 0
    fi

    case "$val" in
        full|brief|off) ;;
        *) die "science is full, brief, or off. Got: ${val}" ;;
    esac

    local f="${PREFS_DIR}/${me}"
    local prev; prev="$(science_pref "$me")"

    # Rewrite rather than append, so the file stays one line per key instead of
    # growing a history that only its last entry ever affects.
    {
        [[ -f "$f" ]] && grep -vE '^science([[:space:]]|$)' "$f" 2>/dev/null
        printf 'science %s\n' "$val"
    } | atomic_write "$f"

    if [[ "$prev" == "$val" ]]; then
        log "Science notes were already ${val}. Nothing changed."
    else
        log "Science notes: ${prev} -> ${val}."
    fi
}

# ---- help: cards nobody has started ------------------------------------------
# Answers one question: is there anything here I could pick up right now.
#
# It never names who owns a card. Someone with spare time needs to know what is
# outstanding, not who is behind, and a list that travels without names is a
# list that can be acted on without it being about anybody.
cmd_help() {
    local part="${1:-}"
    shift || true
    [[ $# -eq 0 ]] || die "bd help takes at most a part. Extra: $*"

    if [[ -z "$part" ]]; then
        [[ -f "$CURRENT" ]] || die "Nothing is set up yet. Try: bd help mavg"
        part="$(awk 'NF {print $1; exit}' "$CURRENT")"
        [[ -n "$part" ]] || die "Nothing is set up yet. Try: bd help mavg"
    fi
    case "$part" in
        mavg|fit) ;;
        *) die "part is mavg or fit. Got: ${part}" ;;
    esac

    local run
    run="$(resolve_run "$part" "")"
    [[ -n "$run" ]] || die "${part}: no current run set."

    local board="${BOARDS_DIR}/${part}_run${run}.board"
    [[ -f "$board" ]] || die "${part}: no board for run ${run}."

    # Downstream products outlive the intermediate ones, so a run that has moved
    # on is finished here whatever the output directories look like now.
    if part_superseded "$run"; then
        log "Run ${run} ${part} is finished. Nothing to pick up."
        return 0
    fi

    # Cards are only worth listing once they have had a fair stretch of time.
    local handed
    handed="$(head -1 "$board" | sed -n 's/.*generated \([0-9-]\{10\}\).*/\1/p')"
    if [[ -n "$handed" ]]; then
        local waited threshold
        waited="$(working_days_since "$handed")"
        threshold="$(cadence_days)"
        if (( waited < threshold )); then
            log "Nothing to pick up right now."
            return 0
        fi
    fi

    declare -A LIVE=()
    local lv_dr lv_verdict lv_count
    while read -r lv_dr lv_verdict lv_count; do
        [[ -n "$lv_dr" ]] && LIVE["$lv_dr"]="${lv_count:--}"
    done < <(validate_all "$part" "$run")

    local -a idle_idx=() idle_dr=()
    local r_idx r_dr rest
    while read -r r_idx r_dr rest; do
        [[ -n "$r_idx" ]] || continue
        [[ "${LIVE[$r_dr]:-}" == "0" ]] || continue
        idle_idx+=("$r_idx")
        idle_dr+=("$r_dr")
    done < <(board_rows "$board")

    if [[ ${#idle_idx[@]} -eq 0 ]]; then
        log "Nothing to pick up right now."
        return 0
    fi

    log "These cards have no output yet."
    log ""
    local i
    for (( i=0; i<${#idle_idx[@]}; i++ )); do
        printf '  %s  %s\n' "${idle_idx[$i]}" "${idle_dr[$i]}"
    done
    log ""
    log "  $(cmd "bd ${part} ${idle_idx[0]}")"
}

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        assign)  cmd_assign "$@" ;;
        mavg)    cmd_cards mavg "$@" ;;
        fit)     cmd_cards fit "$@" ;;
        show)    cmd_show "$@" ;;
        why)     cmd_why "$@" ;;
        set)     cmd_set "$@" ;;
        help)    cmd_help "$@" ;;
        ""|-h|--help)
            cat <<EOF
board.sh: team-mode for pipeline-v2

For members:
  bd mavg                  your date ranges and the exact commands to run them
  bd mavg <card>           just one card, for example: bd mavg 07
  bd fit                   same, for the fitting part
  bd show mavg             the whole board, everyone
  bd why                   what all of this is for, start here
  bd why mavg              what m-averaging is actually doing
  bd why fit               what the fitter is actually doing
  bd set science <choice>  how much science to show alongside your cards
  bd help                  cards nobody has started, if there are any

For the lead:
  bd assign <part> <run> <names...>   deal the date ranges to people
  bd show <part> [run] [name]         the board, or one person's cards

part is mavg or fit. Add --dry-run to preview (assign).
Add --run <run> to any member command to look at a run other than the current one.

Nobody reports completion. A card counts as finished when its output files are
all there, which bd show and bd mavg check for themselves every time they run.
EOF
            ;;
        *) die "unknown subcommand: ${sub}" ;;
    esac
}
main "$@"
