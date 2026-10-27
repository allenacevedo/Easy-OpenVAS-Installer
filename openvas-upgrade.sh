#!/bin/bash
##############################################################################
# Greenbone Vulnerability Manager appliance upgrade script
# Multi-distro support for Ubuntu, Debian & Raspbian
# David Harrop
# October 2026
# Build dependency fixes: 24 October 2026
#
# Stops the GVM services while upgrading. Backs up the database configuration,
# Python environments and replaces program files before migrating the database.
# Keeps existing accounts, passwords, certificates, feeds, cron jobs.
# PostgreSQL receives package updates within its EXISTING major version only.
# A failed upgrade retains its work and backups and leaves GVM stopped for repair.
# restoring a database and its matching binaries is a manual recovery operation.
##############################################################################

##############################################################################
# EDIT BELOW SETTINGS: All custom settings & dependency mgmt is handled in 
# this section. Blank module versions "" select GitHub's latest stable release. 
# Environment overrides are also supported, eg: FORCE_GVMD_VERSION=26.42.0
##############################################################################

# FORCE MODULE VERSIONS or accept default to automatically download latest
FORCE_GVM_LIBS_VERSION="${FORCE_GVM_LIBS_VERSION:-}"
FORCE_GVMD_VERSION="${FORCE_GVMD_VERSION:-}"
FORCE_PG_GVM_VERSION="${FORCE_PG_GVM_VERSION:-}"
FORCE_GSA_VERSION="${FORCE_GSA_VERSION:-}"
FORCE_GSAD_VERSION="${FORCE_GSAD_VERSION:-}"
FORCE_OPENVAS_SMB_VERSION="${FORCE_OPENVAS_SMB_VERSION:-}"
FORCE_OPENVAS_SCANNER_VERSION="${FORCE_OPENVAS_SCANNER_VERSION:-}"
FORCE_OSPD_OPENVAS_VERSION="${FORCE_OSPD_OPENVAS_VERSION:-}" # OSPD_OPENVAS_VERSION always use the selected OPENVAS_SCANNER_VERSION source version.
FORCE_FEED_SYNC_VERSION="${FORCE_FEED_SYNC_VERSION:-}"
FORCE_GVM_TOOLS_VERSION="${FORCE_GVM_TOOLS_VERSION:-}"
FORCE_PYTHON_GVM_VERSION="${FORCE_PYTHON_GVM_VERSION:-}"
FORCE_PYPSRP_CLI_VERSION="${FORCE_PYPSRP_CLI_VERSION:-}"
FORCE_FEED_RELEASE="${FORCE_FEED_RELEASE:-}"

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
PYTHON_ENV_DIR="${PYTHON_ENV_DIR:-/opt/gvm/venvs}"
WORK_ROOT="${WORK_ROOT:-$HOME/openvas-upgrade}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-$HOME/openvas-build-logs}"
DB_NAME="${DB_NAME:-gvmd}"
DB_HOST="${DB_HOST:-/var/run/postgresql}"
DB_PORT="${DB_PORT:-5432}"
POSTGRESQL_MAJOR="${POSTGRESQL_MAJOR:-}" # Blank: detect; a mismatch is rejected.
SYNC_FEEDS="${SYNC_FEEDS:-true}"       # Run the selected feed release after migration.
KEEP_BUILD_FILES="${KEEP_BUILD_FILES:-false}" # Failed runs always retain their files.
SERVICE_CHECK_SECONDS="${SERVICE_CHECK_SECONDS:-15}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-0.2}" # Seconds between updates; fractions such as 0.2 are supported.

# DEPENDENCY MANAGEMENT 
# common
COMMON_DEPS=(build-essential curl cron cmake pkg-config python3 python3-venv
    python3-dev ca-certificates openssl gnupg wget sudo ufw git iproute2
    libffi-dev libxslt1-dev rsync htop postfix mailutils util-linux)

# gvm-libs
GVMLIBS_DEPS=(libglib2.0-dev libgpgme-dev libgnutls28-dev uuid-dev libhiredis-dev
    libxml2-dev libpcap-dev libnet1-dev libpaho-mqtt-dev libldap-dev libradcli-dev
    xmltoman libcjson-dev libcrypt-dev zlib1g-dev libcurl4-gnutls-dev
    libgcrypt20-dev libssh-dev doxygen graphviz)

# gvmd
GVMD_DEPS1=(libglib2.0-dev libgnutls28-dev libpq-dev libical-dev xsltproc rsync
    libgpgme-dev libcjson-dev libbsd-dev)

GVMD_DEPS2=(texlive-latex-extra texlive-fonts-recommended xmlstarlet zip rpm
    fakeroot dpkg nsis gnupg gpgsm wget sshpass openssh-client socat snmp
    python3 smbclient python3-lxml gnutls-bin)

# pg-gvm
PGGVM_DEPS=(libglib2.0-dev libical-dev)

# gsad	
GSAD_DEPS=(libmicrohttpd-dev libxml2-dev libglib2.0-dev libgnutls28-dev
    libbrotli-dev zlib1g-dev libgcrypt20-dev xmltoman doxygen)

# openvas-smb
OPENVASSMB_DEPS=(gcc-mingw-w64 libgnutls28-dev libglib2.0-dev libpopt-dev
    libunistring-dev heimdal-multidev perl-base)

# openvas-scanner
OPENVASSCAN_DEPS=(bison libglib2.0-dev libgnutls28-dev libgcrypt20-dev
    libpcap-dev libgpgme-dev libksba-dev rsync nmap libjson-glib-dev
    libcurl4-gnutls-dev libbsd-dev python3-impacket libsnmp-dev pnscan
    krb5-multidev libmagic-dev capnproto pandoc)

# ospd-openvas
OSPD_DEPS=(python3 python3-venv python3-dev)

# greenbone-feed-sync
FEED_DEPS=(python3 python3-venv)

# gvm-tools
GVMTOOLS_DEPS=(python3 python3-venv python3-dev)

# redis
REDIS_DEPS=(redis-server)

# Rust/native build dependencies
OPENVASD_DEPS=(pkg-config libssl-dev clang libclang-dev bison flex capnproto)
PYPSRP_DEPS=(python3-dev python3-venv libkrb5-dev krb5-user)

##############################################################################
# Do not edit settings below this point.
##############################################################################

GVM_SERVICES=(gsad gvmd ospd-openvas openvasd)
SERVICE_PATH="$INSTALL_PREFIX/bin:$INSTALL_PREFIX/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
MAINTENANCE_STARTED=false
UPGRADE_COMPLETE=false
UPGRADER_PID=$BASHPID
sudo_keepalive_pid=""
RUN_DIR=""
BUILD_LOG=""
BACKUP_DIR=""
PROGRESS_PID=""
PROGRESS_LABEL=""
PROGRESS_STARTED=0
PROGRESS_FD=1
PROGRESS_INLINE=false
OUTPUT_PID=""
GREY="" GREYB="" LGREEN="" LGREENB="" LRED="" LPURPLE="" LPURPLEB="" LYELLOW="" NC=""

clear

init_style() {
    # Detect the terminal before logging redirects stdout; use the installer's palette.
    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
        PROGRESS_INLINE=true
        GREY=$'\033[0;37m'
        GREYB=$'\033[1;37m'
        LGREEN=$'\033[0;92m'
        LGREENB=$'\033[1;92m'
        LRED=$'\033[0;91m'
        LPURPLE=$'\033[0;95m'
        LPURPLEB=$'\033[1;95m'
        LYELLOW=$'\033[0;93m'
        NC=$'\033[0m'
    fi
}

elapsed_time() {
    local seconds="$1"
    printf '%02d:%02d:%02d' "$((seconds / 3600))" "$((seconds / 60 % 60))" "$((seconds % 60))"
}

validate_progress_interval() {
    [[ "$PROGRESS_INTERVAL" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ && "$PROGRESS_INTERVAL" == *[1-9]* ]] ||
        die 'PROGRESS_INTERVAL must be greater than zero (for example, 0.2 or 10).'
}

print_progress() {
    local complete="$1" text="$2"
    if [[ "$PROGRESS_INLINE" == true ]]; then
        # Send a complete record to the same pipe as command output. A single
        # terminal writer prevents the spinner and compiler messages colliding.
        printf '\036%s%s\037' "$complete" "$text"
    else
        printf '%s\n' "$text"
    fi
}

terminal_output() {
    exec 9>&-
    trap - ERR EXIT INT TERM HUP
    "$PYTHON_BIN" -u - "$BUILD_LOG" 4<&0 <<'PY'
import os
import re
import sys

ansi = re.compile(rb"\x1b\[[0-9;]*m")
output = sys.stdout.buffer
log = open(sys.argv[1], "ab", buffering=0)
visible = False
line_start = True

def command_output(data):
    global visible, line_start
    if not data:
        return
    log.write(data)
    if visible:
        output.write(b"\r\x1b[2K")
        visible = False
    # Reset the column explicitly, even while sudo changes terminal settings.
    output.write(data.replace(b"\n", b"\r\n"))
    line_start = data.endswith((b"\n", b"\r"))
    output.flush()

def progress(record):
    global visible, line_start
    complete, text = record[:1] == b"1", record[1:]
    plain = ansi.sub(b"", text).decode("utf-8", errors="replace")
    log.write(plain.encode("utf-8") + b"\n")
    # Never erase a command's unfinished output line for a timer update.
    if not line_start and not complete:
        return
    if not line_start:
        output.write(b"\r\n")
    try:
        width = max(1, os.get_terminal_size(1).columns - 1)
    except OSError:
        width = 79
    if len(plain) > width:
        # Keep elapsed time visible and avoid wrapping onto another screen row.
        suffix = re.search(r" \[(?:exit \d+; )?\d+:\d{2}:\d{2} elapsed\]$", plain)
        tail = suffix.group() if suffix else ""
        room = width - len(tail)
        clipped = plain[:max(0, room - 3)] + "..." + tail if room >= 3 else plain[-width:]
        colour = ansi.match(text)
        text = (colour.group() if colour else b"") + clipped.encode("utf-8") + b"\x1b[0m"
    output.write(b"\r\x1b[2K" + text)
    visible = not complete
    line_start = True
    if complete:
        output.write(b"\r\n")
    output.flush()

pending = b""
while True:
    chunk = os.read(4, 65536)
    if not chunk:
        break
    pending += chunk
    while pending:
        start = pending.find(b"\x1e")
        if start < 0:
            command_output(pending)
            pending = b""
            break
        command_output(pending[:start])
        pending = pending[start:]
        end = pending.find(b"\x1f", 1)
        if end < 0:
            break
        record, pending = pending[1:end], pending[end + 1:]
        if record[:1] in (b"0", b"1"):
            progress(record)
        else:
            command_output(b"\x1e" + record + b"\x1f")
command_output(pending)
if visible:
    output.write(b"\r\n")
    output.flush()
PY
}

start_logging() {
    exec 3>&1 4>&2
    PROGRESS_FD=1
    if [[ "$PROGRESS_INLINE" == true ]]; then
        exec > >(terminal_output) 2>&1
    else
        exec > >(tee -a "$BUILD_LOG") 2>&1
    fi
    OUTPUT_PID=$!
}

progress_loop() {
    local parent_pid="$1" started="$2" label="$3"
    local frames='|/-\' frame=0 elapsed sleeper=""
    # This helper only reports status; the actual task stays in the main shell.
    # Closing its copy of the lock and reaping sleep allow immediate clean exit.
    exec 9>&-
    trap - ERR EXIT
    trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi' EXIT
    trap 'exit 0' INT TERM HUP
    while kill -0 "$parent_pid" 2>/dev/null; do
        sleep "$PROGRESS_INTERVAL" &
        sleeper=$!
        wait "$sleeper"
        sleeper=""
        elapsed=$((SECONDS - started))
        print_progress 0 "${LPURPLE}[${frames:frame%${#frames}:1}]${NC} $label [$(elapsed_time "$elapsed") elapsed]" >&"$PROGRESS_FD"
        frame=$((frame + 1))
    done
}

finish_progress() {
    local status="${1:-0}" elapsed
    if [[ -n "$PROGRESS_PID" ]]; then
        kill "$PROGRESS_PID" 2>/dev/null || true
        wait "$PROGRESS_PID" 2>/dev/null || true
        PROGRESS_PID=""
    fi
    if [[ -n "$PROGRESS_LABEL" ]]; then
        elapsed=$(elapsed_time "$((SECONDS - PROGRESS_STARTED))")
        if (( status == 0 )); then
            print_progress 1 "${LGREEN}[OK] $PROGRESS_LABEL [$elapsed elapsed]${NC}"
        else
            print_progress 1 "${LRED}[FAILED] $PROGRESS_LABEL [exit $status; $elapsed elapsed]${NC}" >&2
        fi
        PROGRESS_LABEL=""
    fi
}

run_task() {
    PROGRESS_LABEL="$1"
    shift
    PROGRESS_STARTED=$SECONDS
    print_progress 0 "${LPURPLE}[>]${NC} $PROGRESS_LABEL ..."
    progress_loop "$$" "$PROGRESS_STARTED" "$PROGRESS_LABEL" &
    PROGRESS_PID=$!
    # Keep output live and run in this shell so exports and error handling survive.
    "$@"
    finish_progress 0
}

save_output() {
    local destination="$1"
    shift
    "$@" > "$destination"
}

die() {
    finish_progress 1
    printf '\n%sERROR: %s%s\n' "$LRED" "$*" "$NC" >&2
    exit 1
}

section() {
    printf '\n%s##############################################################################\n %s\n##############################################################################%s\n\n' \
        "$LGREEN" "$*" "$NC"
}

upgrade_failed() {
    local status="$1" line="$2"
    trap - ERR
    finish_progress "$status"
    printf '\n%sUpgrade failed at line %s (exit %s).\nLog: %s%s\n' \
        "$LRED" "$line" "$status" "$BUILD_LOG" "$NC" >&2
    exit "$status"
}

cleanup() {
    local status=$?
    # A reporter killed just after forking may still inherit this EXIT trap.
    # Only the main shell may finish tasks, stop services or drain the log pipe.
    [[ "$BASHPID" == "$UPGRADER_PID" ]] || return "$status"
    trap - EXIT ERR
    finish_progress "$status"
    if [[ "$MAINTENANCE_STARTED" == true && "$UPGRADE_COMPLETE" != true ]]; then
        # Do not leave a partially upgraded set of daemons running after a failure.
        sudo -n systemctl stop "${GVM_SERVICES[@]}" || true
        printf '\nGVM services were stopped. Work and backups retained at: %s\n' "$RUN_DIR" >&2
    fi
    if [[ -n "$sudo_keepalive_pid" ]]; then
        kill "$sudo_keepalive_pid" 2>/dev/null || true
        wait "$sudo_keepalive_pid" 2>/dev/null || true
    fi
    if [[ -n "$OUTPUT_PID" ]]; then
        # Drain the output pipe before returning, including the final result.
        exec 1>&3 2>&4
        wait "$OUTPUT_PID" || true
        OUTPUT_PID=""
    fi
    return "$status"
}

start_sudo_keepalive() {
    local upgrader_pid=$$
    sudo -v
    (
        # Do not let the refresher hold the upgrade lock after the parent exits.
        exec 9>&-
        sleeper=""
        trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi' EXIT
        trap 'exit 0' TERM INT HUP
        while kill -0 "$upgrader_pid" 2>/dev/null; do
            sudo -n -v || exit 1
            sleep 60 &
            sleeper=$!
            wait "$sleeper"
            sleeper=""
        done
    ) &
    sudo_keepalive_pid=$!
}

as_postgres() {
    (cd /; sudo -H -u postgres "$@")
}

psql_db() {
    as_postgres "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 \
        --host="$DB_HOST" --port="$DB_PORT" --dbname="$DB_NAME" "$@"
}

as_gvm() {
    (cd /; sudo -H -u gvm env PATH="$SERVICE_PATH" "$@")
}

select_postgresql_major() {
    local server_version="$1" detected
    [[ "$server_version" =~ ^[0-9]+$ ]] || die "Cannot determine the existing PostgreSQL server version."
    detected=$((server_version / 10000))
    [[ -z "$POSTGRESQL_MAJOR" || "$POSTGRESQL_MAJOR" == "$detected" ]] || \
        die "PostgreSQL $detected is running; this script does not change its major version."
    POSTGRESQL_MAJOR="$detected"
}

detect_postgresql() {
    local server_version
    server_version=$(as_postgres psql -X -At --host="$DB_HOST" --port="$DB_PORT" \
        --dbname="$DB_NAME" -c 'SHOW server_version_num;')
    select_postgresql_major "$server_version"
    PG_BIN="/usr/lib/postgresql/$POSTGRESQL_MAJOR/bin"
    PG_CONFIG="$PG_BIN/pg_config"
    [[ -x "$PG_CONFIG" && -x "$PG_BIN/pg_dump" ]] || die "Missing PostgreSQL $POSTGRESQL_MAJOR tools."
    printf 'POSTGRESQL_MAJOR=%s\n' "$POSTGRESQL_MAJOR" >> "$VERSION_LOG"
    printf 'Existing PostgreSQL major: %s\n' "$POSTGRESQL_MAJOR"
}

check_existing_installation() {
    local binary app service state
    id gvm >/dev/null
    for binary in sbin/gvmd sbin/gsad sbin/openvas bin/openvasd bin/scannerctl; do
        [[ -x "$INSTALL_PREFIX/$binary" ]] || die "Existing executable missing: $INSTALL_PREFIX/$binary"
    done
    for app in ospd-openvas greenbone-feed-sync gvm-tools pypsrp-cli; do
        [[ -x "$PYTHON_ENV_DIR/$app/bin/python" ]] || die "Existing Python environment missing: $app"
    done
    for binary in /etc/openvas/openvas.conf /etc/redis/redis-openvas.conf; do
        sudo test -f "$binary" || die "Existing configuration missing: $binary"
    done
    for service in "${GVM_SERVICES[@]}" redis-server@openvas; do
        state=$(systemctl show "$service.service" --property=LoadState --value)
        [[ "$state" == loaded ]] || die "Existing service missing: $service.service"
    done
    read -r GVMD_OWNER GVMD_MODE < <(stat -Lc '%u:%g %a' "$INSTALL_PREFIX/sbin/gvmd")
    [[ -n "$GVMD_OWNER" && "$GVMD_MODE" =~ ^[0-7]+$ ]] || die "Cannot record gvmd permissions."
}

get_latest_release() {
    local response
    response=$(curl -f -sS -L --retry 3 "https://api.github.com/repos/$1/releases/latest")
    "$PYTHON_BIN" -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])' <<< "$response"
}

resolve_versions() {
    local version forced selected
    local -A repos=(
        [GVM_LIBS_VERSION]=greenbone/gvm-libs [GVMD_VERSION]=greenbone/gvmd
        [PG_GVM_VERSION]=greenbone/pg-gvm [GSA_VERSION]=greenbone/gsa
        [GSAD_VERSION]=greenbone/gsad [OPENVAS_SMB_VERSION]=greenbone/openvas-smb
        [OPENVAS_SCANNER_VERSION]=greenbone/openvas-scanner
        [OSPD_OPENVAS_VERSION]=greenbone/ospd-openvas
        [FEED_SYNC_VERSION]=greenbone/greenbone-feed-sync
        [GVM_TOOLS_VERSION]=greenbone/gvm-tools [PYTHON_GVM_VERSION]=greenbone/python-gvm
        [PYPSRP_CLI_VERSION]=greenbone/pypsrp-cli
    )
    for version in GVM_LIBS_VERSION GVMD_VERSION PG_GVM_VERSION GSA_VERSION GSAD_VERSION \
        OPENVAS_SMB_VERSION OPENVAS_SCANNER_VERSION OSPD_OPENVAS_VERSION \
        FEED_SYNC_VERSION GVM_TOOLS_VERSION PYTHON_GVM_VERSION PYPSRP_CLI_VERSION; do
        forced="FORCE_$version"
        if [[ -n "${!forced}" ]]; then
            selected="${!forced}"
        else
            printf '%sChecking latest %s release...%s\n' "$LPURPLE" "${repos[$version]#greenbone/}" "$NC"
            selected=$(get_latest_release "${repos[$version]}")
        fi
        selected="${selected#v}"
        [[ "$selected" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || \
            die "Invalid release for ${repos[$version]}: $selected"
        printf -v "$version" '%s' "$selected"
        export "$version"
        printf '%s%s=%s%s\n' "$LGREEN" "$version" "$selected" "$NC"
        printf 'FORCE_%s=%s\n' "$version" "$selected" >> "$VERSION_LOG"
    done
    local major="${GVMD_VERSION%%.*}"
    if [[ -n "$FORCE_FEED_RELEASE" ]]; then
        FEED_RELEASE="$FORCE_FEED_RELEASE"
    elif (( major >= 25 )); then
        FEED_RELEASE=25.0
    elif (( major < 24 )); then
        FEED_RELEASE=22.04
    else
        die "gvmd 24.x needs an explicitly selected compatible FORCE_FEED_RELEASE."
    fi
    [[ "$FEED_RELEASE" =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid feed release: $FEED_RELEASE"
    printf 'FEED_RELEASE=%s\n' "$FEED_RELEASE" >> "$VERSION_LOG"
    printf 'FORCE_FEED_RELEASE=%s\n' "${FORCE_FEED_RELEASE:-}" >> "$VERSION_LOG"
}

reject_gvmd_downgrade() {
    local output current
    output=$(as_gvm "$INSTALL_PREFIX/sbin/gvmd" --version 2>&1)
    current=$(sed -n 's/^Greenbone Vulnerability Manager \([0-9][0-9.]*\).*/\1/p' <<< "$output")
    [[ -n "$current" ]] || die "Cannot read the installed gvmd version."
    dpkg --compare-versions "$GVMD_VERSION" ge "$current" || \
        die "Refusing gvmd downgrade $current -> $GVMD_VERSION; database downgrades are not supported."
    printf 'INSTALLED_GVMD_VERSION=%s\n' "$current" >> "$VERSION_LOG"
}

download_source() {
    local component="$1" version="$2" signature="${3:-}"
    local archive="$SOURCE_DIR/$component-$version.tar.gz"
    run_task "Downloading $component $version" \
        curl -f -sS -L --retry 3 "https://github.com/greenbone/$component/archive/refs/tags/v$version.tar.gz" -o "$archive"
    if [[ -n "$signature" ]]; then
        run_task "Downloading $component signature" \
            curl -f -sS -L --retry 3 "https://github.com/greenbone/$component/releases/download/v$version/$signature" -o "$archive.asc"
        run_task "Verifying $component signature" gpg --batch --verify "$archive.asc" "$archive"
    fi
    run_task "Extracting $component $version" tar -C "$SOURCE_DIR" -xzf "$archive"
}

download_all_sources() {
    # Build signing keys are isolated from the existing feed verification keyring.
    export GNUPGHOME="$RUN_DIR/gnupg"
    mkdir -m 700 "$GNUPGHOME"
    run_task 'Downloading the Greenbone signing key' \
        curl -f -sS -L --retry 3 https://www.greenbone.net/GBCommunitySigningKey.asc -o "$RUN_DIR/signing-key.asc"
    gpg --batch --import "$RUN_DIR/signing-key.asc"
    printf '8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:\n' | gpg --batch --import-ownertrust
    download_source gvm-libs "$GVM_LIBS_VERSION" "gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc"
    download_source gvmd "$GVMD_VERSION" "gvmd-$GVMD_VERSION.tar.gz.asc"
    download_source pg-gvm "$PG_GVM_VERSION" "pg-gvm-$PG_GVM_VERSION.tar.gz.asc"
    download_source gsad "$GSAD_VERSION" "gsad-$GSAD_VERSION.tar.gz.asc"
    download_source openvas-smb "$OPENVAS_SMB_VERSION" "openvas-smb-v$OPENVAS_SMB_VERSION.tar.gz.asc"
    download_source openvas-scanner "$OPENVAS_SCANNER_VERSION" "openvas-scanner-v$OPENVAS_SCANNER_VERSION.tar.gz.asc"
    download_source ospd-openvas "$OSPD_OPENVAS_VERSION" "ospd-openvas-v$OSPD_OPENVAS_VERSION.tar.gz.asc"
    download_source greenbone-feed-sync "$FEED_SYNC_VERSION" "greenbone-feed-sync-$FEED_SYNC_VERSION.tar.gz.asc"
    download_source python-gvm "$PYTHON_GVM_VERSION" "python-gvm-$PYTHON_GVM_VERSION.tar.gz.asc"
    download_source gvm-tools "$GVM_TOOLS_VERSION" "gvm-tools-$GVM_TOOLS_VERSION.tar.gz.asc"
    # This helper does not publish detached release signatures.
    download_source pypsrp-cli "$PYPSRP_CLI_VERSION"
    local archive="$SOURCE_DIR/gsa-$GSA_VERSION.tar.gz"
    run_task "Downloading GSA $GSA_VERSION" \
        curl -f -sS -L --retry 3 "https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz" -o "$archive"
    run_task 'Downloading the GSA signature' \
        curl -f -sS -L --retry 3 "https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz.asc" -o "$archive.asc"
    run_task 'Verifying the GSA signature' gpg --batch --verify "$archive.asc" "$archive"
    mkdir "$SOURCE_DIR/gsa-$GSA_VERSION"
    run_task "Extracting GSA $GSA_VERSION" tar -C "$SOURCE_DIR/gsa-$GSA_VERSION" -xzf "$archive"
    [[ -f "$SOURCE_DIR/gsa-$GSA_VERSION/index.html" ]] || die "The GSA archive has no index.html."
}

backup_existing_system() {
    local path
    mkdir -m 700 "$BACKUP_DIR"
    psql_db -At -c 'SELECT version();' > "$BACKUP_DIR/postgresql-version.txt"
    run_task 'Backing up the GVMD database' save_output "$BACKUP_DIR/gvmd.dump" \
        as_postgres "$PG_BIN/pg_dump" --host="$DB_HOST" --port="$DB_PORT" --format=custom --dbname="$DB_NAME"
    run_task 'Backing up PostgreSQL global roles' save_output "$BACKUP_DIR/postgresql-globals.sql" \
        as_postgres "$PG_BIN/pg_dumpall" --host="$DB_HOST" --port="$DB_PORT" --globals-only
    local -a config_paths=()
    for path in etc/gvm etc/openvas etc/redis/redis-openvas.conf etc/ssl \
        etc/systemd/system etc/ld.so.conf.d/gvm-local.conf; do
        if sudo test -e "/$path"; then config_paths+=("$path"); fi
    done
    run_task 'Backing up configuration and certificates' save_output "$BACKUP_DIR/configuration.tar.gz" \
        sudo tar -C / -czf - "${config_paths[@]}"
    run_task 'Backing up the existing Python environments' sudo cp -a "$PYTHON_ENV_DIR" "$BACKUP_DIR/venvs"
    printf '%sBackups: %s%s\n' "$LGREEN" "$BACKUP_DIR" "$NC"
}

install_dependencies() {
    # Upgrade the named dependencies only. Keep existing conffiles and repositories.
    run_task 'Refreshing APT package lists' sudo env DEBIAN_FRONTEND=noninteractive apt-get update
    run_task 'Updating OpenVAS build and runtime dependencies' \
        sudo env DEBIAN_FRONTEND=noninteractive apt-get --assume-yes \
        --no-install-recommends -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold install \
        "${COMMON_DEPS[@]}" "${GVMLIBS_DEPS[@]}" "${GVMD_DEPS1[@]}" \
        "${GVMD_DEPS2[@]}" "${PGGVM_DEPS[@]}" "${GSAD_DEPS[@]}" \
        "${OPENVASSMB_DEPS[@]}" "${OPENVASSCAN_DEPS[@]}" "${OSPD_DEPS[@]}" \
        "${FEED_DEPS[@]}" "${GVMTOOLS_DEPS[@]}" "${REDIS_DEPS[@]}" \
        "${OPENVASD_DEPS[@]}" "${PYPSRP_DEPS[@]}" \
        "postgresql-$POSTGRESQL_MAJOR" "postgresql-server-dev-$POSTGRESQL_MAJOR"
    "$PG_CONFIG" --version
    local server_version
    server_version=$(psql_db -At -c 'SHOW server_version_num;')
    [[ "$server_version" =~ ^[0-9]+$ ]] && \
        (( server_version / 10000 == POSTGRESQL_MAJOR )) || die "PostgreSQL major changed unexpectedly."
}

deploy_stage() {
    # Upstream install targets contain default configuration and service files.
    # Exclude these even when they were generated by make/cmake install.
    run_task "Installing $(basename "$1") program files" \
        sudo rsync -rl --keep-dirlinks --backup --backup-dir="$BACKUP_DIR/files" \
        --exclude='/etc/***' --exclude='/var/***' --exclude='/run/***' \
        --exclude="$INSTALL_PREFIX/etc/***" \
        --exclude='/lib/systemd/***' --exclude='/usr/lib/systemd/***' \
        --exclude="$INSTALL_PREFIX/lib/systemd/***" \
        "$1/" /
}

build_cmake() {
    local component="$1" version="$2"
    shift 2
    section "Building $component $version"
    run_task "Configuring $component $version" \
        cmake -S "$SOURCE_DIR/$component-$version" -B "$BUILD_DIR/$component" "$@"
    run_task "Compiling $component $version" cmake --build "$BUILD_DIR/$component" --parallel "$(nproc)"
    run_task "Staging $component $version" env DESTDIR="$INSTALL_DIR/$component" cmake --install "$BUILD_DIR/$component"
    deploy_stage "$INSTALL_DIR/$component"
    sudo ldconfig
}

# Fix HTTPS redirects to use --port (443), rather than --rport (80).
patch_gsad_redirect() {
    "$PYTHON_BIN" - "$SOURCE_DIR/gsad-$GSAD_VERSION/src/gsad.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
broken = 'g_strdup_printf ("https://%%s:%i/", redirect_port);'
fixed = 'g_strdup_printf ("https://%%s:%i/", gsad_args_get_port (gsad_args));'
if broken in source:
    path.write_text(source.replace(broken, fixed))
    print("Applied GSAD HTTP-to-HTTPS redirect port fix.")
PY
}

prepare_native_archives() {
    local scanner="$1" krb5_version pcap_version part archive
    local krb5_prefix="$BUILD_DIR/openvas-static/krb5"
    local pcap_prefix="$BUILD_DIR/openvas-static/pcap"
    krb5_version=$(sed -n 's/^ARG KRB5_VERSION=\([0-9][0-9.]*\)$/\1/p' "$scanner/.docker/prod.Dockerfile")
    pcap_version=$(sed -n 's/^ARG LIBPCAP_VERSION=\([0-9][0-9.]*\)$/\1/p' "$scanner/.docker/prod.Dockerfile")
    [[ -n "$krb5_version" && -n "$pcap_version" ]] || die "Scanner source does not declare the expected native dependency versions."
    [[ -x "$scanner/.docker/vendor/krb5-$krb5_version/src/configure" ]] || die "Vendored MIT Kerberos source is missing."
    [[ -x "$scanner/.docker/vendor/libpcap-$pcap_version/configure" ]] || die "Vendored libpcap source is missing."
    (
        cd "$scanner/.docker/vendor/krb5-$krb5_version/src"
        run_task "Configuring static Kerberos $krb5_version" \
            ./configure --prefix="$krb5_prefix" --enable-static --disable-shared \
            --without-system-verto --without-libedit --without-keyutils --disable-rpath
        for part in util/support util/et util/profile include lib/crypto lib/krb5 lib/gssapi; do
            run_task "Compiling Kerberos: $part" make -C "$part" -j"$(nproc)"
        done
        run_task 'Preparing the static Kerberos installation' make install-mkdirs
        for part in util/support util/et util/profile include lib/crypto lib/krb5 lib/gssapi; do
            run_task "Installing Kerberos: $part" make -C "$part" install
        done
    )
    (
        cd "$scanner/.docker/vendor/libpcap-$pcap_version"
        run_task "Configuring static libpcap $pcap_version" \
            ./configure --prefix="$pcap_prefix" --disable-shared --disable-dbus \
            --without-libnl --disable-usb --disable-bluetooth --disable-rdma
        run_task "Compiling static libpcap $pcap_version" make -j"$(nproc)"
        run_task "Installing static libpcap $pcap_version" make install
    )
    export OPENVAS_KRB5_INCLUDE_DIR="$krb5_prefix/include"
    export OPENVAS_KRB5_ARCHIVES=""
    for archive in libgssapi_krb5.a libkrb5.a libk5crypto.a libcom_err.a libkrb5support.a; do
        [[ -f "$krb5_prefix/lib/$archive" ]] || die "Native archive missing: $archive"
        OPENVAS_KRB5_ARCHIVES+="${OPENVAS_KRB5_ARCHIVES:+:}$krb5_prefix/lib/$archive"
    done
    for part in krb5.h gssapi/gssapi.h gssapi/gssapi_krb5.h; do
        [[ -f "$OPENVAS_KRB5_INCLUDE_DIR/$part" ]] || die "Native header missing: $part"
    done
    export LIBPCAP_LIBDIR="$pcap_prefix/lib"
    export LIBPCAP_VER="$pcap_version"
    [[ -f "$LIBPCAP_LIBDIR/libpcap.a" ]] || die "Native libpcap archive missing."
    [[ -f "$pcap_prefix/include/pcap.h" ]] || die "Native libpcap header missing."
    printf 'KRB5_VERSION=%s\nLIBPCAP_VERSION=%s\n' "$krb5_version" "$pcap_version" >> "$VERSION_LOG"
}

build_rust_scanner() {
    local scanner="$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION" rust_toolchain
    if [[ ! -x "$HOME/.cargo/bin/rustup" ]]; then
        run_task 'Downloading Rustup' \
            curl --proto '=https' --tlsv1.2 -f -sS -L --retry 3 https://sh.rustup.rs -o "$BUILD_DIR/rustup-init.sh"
        run_task 'Installing Rustup' sh "$BUILD_DIR/rustup-init.sh" -y --profile minimal --no-modify-path
    fi
    source "$HOME/.cargo/env"
    if [[ -f "$scanner/rust/crates/nasl-c-lib/libopenvas-krb5-sys/build.rs" ]]; then
        prepare_native_archives "$scanner"
    fi
    cd "$scanner/rust"
    if [[ -f rust-toolchain.toml ]]; then
        rust_toolchain=$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' rust-toolchain.toml)
        [[ "$rust_toolchain" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]] || die "Cannot read the scanner's Rust toolchain."
        run_task "Preparing Rust toolchain $rust_toolchain" rustup toolchain install "$rust_toolchain" --profile minimal
        export RUSTUP_TOOLCHAIN="$rust_toolchain"
    fi
    rustc --version
    cargo --version
    printf 'RUST_VERSION=%q\nCARGO_VERSION=%q\n' "$(rustc --version)" "$(cargo --version)" >> "$VERSION_LOG"
    [[ -f Cargo.lock ]] || die "The scanner release does not contain Cargo.lock."
    BIN_VERSION="$OPENVAS_SCANNER_VERSION" run_task "Compiling openvasd and scannerctl $OPENVAS_SCANNER_VERSION" \
        cargo build --locked --release \
        --bin openvasd --bin scannerctl --target-dir "$BUILD_DIR/openvasd-target"
    mkdir -p "$INSTALL_DIR/rust$INSTALL_PREFIX/bin"
    install -m 755 "$BUILD_DIR/openvasd-target/release/openvasd" "$INSTALL_DIR/rust$INSTALL_PREFIX/bin/openvasd"
    install -m 755 "$BUILD_DIR/openvasd-target/release/scannerctl" "$INSTALL_DIR/rust$INSTALL_PREFIX/bin/scannerctl"
    deploy_stage "$INSTALL_DIR/rust"
}

upgrade_python_app() {
    local name="$1" compiler build_path="$PATH"
    shift
    local venv="$PYTHON_ENV_DIR/$name"
    if [[ -x "$HOME/.cargo/bin/rustup" ]] && compiler=$("$HOME/.cargo/bin/rustup" which rustc 2>/dev/null); then
        build_path="$(dirname "$compiler"):$build_path"
    fi
    # Upgrade the existing isolated environment; do not clear system or app Python.
    run_task "Updating pip in the $name environment" \
        sudo env PATH="$venv/bin:$build_path" "$venv/bin/python" -m pip install --upgrade pip
    run_task "Updating $name and its Python dependencies" \
        sudo env PATH="$venv/bin:$build_path" "$venv/bin/python" -m pip install \
        --upgrade --upgrade-strategy only-if-needed "$@"
    run_task "Checking $name dependency consistency" "$venv/bin/python" -m pip check
    (umask 077; "$venv/bin/python" -m pip list --format=freeze > "$BUILD_LOG_DIR/$BUILD_ID-$name-requirements.txt")
}

link_python_commands() {
    local name="$1" command
    shift
    for command in "$@"; do
        [[ -x "$PYTHON_ENV_DIR/$name/bin/$command" ]] || die "Missing Python command: $command"
        sudo ln -sfn "$PYTHON_ENV_DIR/$name/bin/$command" "$INSTALL_PREFIX/bin/$command"
    done
}

upgrade_python_apps() {
    upgrade_python_app ospd-openvas "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION"
    link_python_commands ospd-openvas ospd-openvas
    "$PYTHON_ENV_DIR/ospd-openvas/bin/ospd-openvas" --help >/dev/null
    "$PYTHON_ENV_DIR/ospd-openvas/bin/python" -c 'from importlib.metadata import version; print("ospd-openvas " + version("ospd-openvas"))'
    upgrade_python_app greenbone-feed-sync "$SOURCE_DIR/greenbone-feed-sync-$FEED_SYNC_VERSION"
    link_python_commands greenbone-feed-sync greenbone-feed-sync greenbone-nvt-sync \
        greenbone-scapdata-sync greenbone-certdata-sync
    "$PYTHON_ENV_DIR/greenbone-feed-sync/bin/greenbone-feed-sync" --version
    upgrade_python_app gvm-tools "$SOURCE_DIR/python-gvm-$PYTHON_GVM_VERSION" "$SOURCE_DIR/gvm-tools-$GVM_TOOLS_VERSION"
    link_python_commands gvm-tools gvm-cli gvm-script gvm-pyshell
    "$PYTHON_ENV_DIR/gvm-tools/bin/gvm-cli" --help >/dev/null
    local -a windows_packages=("$SOURCE_DIR/pypsrp-cli-$PYPSRP_CLI_VERSION")
    local impacket_command
    # Also upgrade Impacket when a previous run installed the isolated fallback.
    if [[ -x "$PYTHON_ENV_DIR/pypsrp-cli/bin/wmiexec.py" || \
          -x "$PYTHON_ENV_DIR/pypsrp-cli/bin/impacket-wmiexec" ]] || \
        ! as_gvm impacket-wmiexec -h; then
        windows_packages+=(impacket)
    fi
    upgrade_python_app pypsrp-cli "${windows_packages[@]}"
    link_python_commands pypsrp-cli pypsrp-cli
    if (( ${#windows_packages[@]} > 1 )); then
        impacket_command="$PYTHON_ENV_DIR/pypsrp-cli/bin/impacket-wmiexec"
        [[ -x "$impacket_command" ]] || impacket_command="$PYTHON_ENV_DIR/pypsrp-cli/bin/wmiexec.py"
        [[ -x "$impacket_command" ]] || die "The Impacket environment did not install a WMI command."
        sudo ln -sfn "$impacket_command" "$INSTALL_PREFIX/bin/impacket-wmiexec"
    fi
    as_gvm pypsrp-cli --help >/dev/null
    as_gvm impacket-wmiexec -h >/dev/null
}

verify_binaries() {
    sudo ldconfig
    "$INSTALL_PREFIX/sbin/openvas" --version
    as_gvm "$INSTALL_PREFIX/sbin/gvmd" --version
    "$INSTALL_PREFIX/sbin/gsad" --version
    "$INSTALL_PREFIX/bin/openvasd" --version
    "$INSTALL_PREFIX/bin/scannerctl" --help >/dev/null
}

migrate_database() {
    # Refresh the loader BEFORE invoking the new executable or extension library.
    sudo ldconfig
    run_task 'Updating the PostgreSQL pg-gvm extension' psql_db -c 'ALTER EXTENSION "pg-gvm" UPDATE;'
    run_task 'Migrating the GVMD database' as_gvm "$INSTALL_PREFIX/sbin/gvmd" --migrate --database="$DB_NAME" \
        --db-host="$DB_HOST" --db-port="$DB_PORT"
}

start_services() {
    run_task 'Restarting the existing OpenVAS Redis instance' sudo systemctl restart redis-server@openvas.service
    run_task 'Starting OpenVAS services' sudo systemctl start openvasd.service ospd-openvas.service gvmd.service gsad.service
    run_task "Waiting $SERVICE_CHECK_SECONDS seconds for service startup" sleep "$SERVICE_CHECK_SECONDS"
    local service
    for service in redis-server@openvas "${GVM_SERVICES[@]}"; do
        run_task "Checking $service.service" sudo systemctl is-active --quiet "$service.service"
    done
}

upgrade_components() {
    build_cmake gvm-libs "$GVM_LIBS_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
        -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var
    build_cmake gvmd "$GVMD_VERSION" \
        -DPG_CONFIG_EXECUTABLE="$PG_CONFIG" -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DCMAKE_BUILD_TYPE=Release -DLOCALSTATEDIR=/var -DSYSCONFDIR=/etc \
        -DGVM_DATA_DIR=/var -DGVMD_RUN_DIR=/run/gvmd \
        -DOPENVAS_DEFAULT_SOCKET=/run/ospd/ospd-openvas.sock \
        -DGVM_FEED_LOCK_PATH=/var/lib/gvm/feed-update.lock \
        -DSYSTEMD_SERVICE_DIR=/lib/systemd/system -DLOGROTATE_DIR=/etc/logrotate.d
    sudo chown "$GVMD_OWNER" "$INSTALL_PREFIX/sbin/gvmd"
    sudo chmod "$GVMD_MODE" "$INSTALL_PREFIX/sbin/gvmd"
    build_cmake pg-gvm "$PG_GVM_VERSION" -DPGCONFIG="$PG_CONFIG" -DCMAKE_BUILD_TYPE=Release
    section "Updating GSA $GSA_VERSION"
    # Only this generated web distribution is pruned; no deletion is used at /.
    run_task "Installing GSA $GSA_VERSION web assets" \
        sudo rsync -rl --delete --keep-dirlinks --backup --backup-dir="$BACKUP_DIR/web" \
        "$SOURCE_DIR/gsa-$GSA_VERSION/" "$INSTALL_PREFIX/share/gvm/gsad/web/"
    patch_gsad_redirect
    build_cmake gsad "$GSAD_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
        -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var -DGVMD_RUN_DIR=/run/gvmd \
        -DGSAD_RUN_DIR=/run/gsad -DLOGROTATE_DIR=/etc/logrotate.d
    build_cmake openvas-smb "$OPENVAS_SMB_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release
    build_cmake openvas-scanner "$OPENVAS_SCANNER_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
        -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var \
        -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock -DOPENVAS_RUN_DIR=/run/ospd
    section "Building openvasd and scannerctl $OPENVAS_SCANNER_VERSION"
    build_rust_scanner
    section 'Upgrading isolated Python applications'
    upgrade_python_apps
}

perform_upgrade() {
    section 'Checking the existing OpenVAS installation'
    run_task 'Checking executables, configuration and services' check_existing_installation
    run_task 'Checking the existing PostgreSQL installation' detect_postgresql
    section 'Selecting OpenVAS releases'
    resolve_versions
    reject_gvmd_downgrade
    section 'Downloading and verifying selected sources'
    download_all_sources
    section 'Stopping GVM and backing up the existing installation'
    MAINTENANCE_STARTED=true
    run_task 'Stopping OpenVAS services for the upgrade' sudo systemctl stop "${GVM_SERVICES[@]}"
    backup_existing_system
    section 'Updating build and runtime dependency packages'
    install_dependencies
    local multiarch
    multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
    export PKG_CONFIG_PATH="$INSTALL_PREFIX/lib/pkgconfig:$INSTALL_PREFIX/lib/$multiarch/pkgconfig:$INSTALL_PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    upgrade_components
    section 'Verifying the upgraded executables'
    run_task 'Checking installed executable and library dependencies' verify_binaries
    section 'Updating the PostgreSQL extension and migrating gvmd'
    migrate_database
    if [[ "$SYNC_FEEDS" == true ]]; then
        section "Synchronizing existing feeds (release $FEED_RELEASE)"
        run_task "Synchronizing Greenbone feeds, release $FEED_RELEASE" \
            sudo -H "$INSTALL_PREFIX/bin/greenbone-feed-sync" --quiet --feed-release "$FEED_RELEASE" --fail-fast
    fi
    section 'Starting and checking the existing services'
    start_services
    UPGRADE_COMPLETE=true
    if [[ "$KEEP_BUILD_FILES" != true ]]; then
        cd "$HOME"
        # Python builds run under sudo and can leave root-owned metadata here.
        run_task 'Removing temporary build files' sudo rm -rf -- "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"
    fi

    run_task "Removing unused APT packages" sudo apt-get autoremove -qq -y
    
    section 'OpenVAS upgrade complete'
    printf '%sLog: %s\nResolved versions: %s\nBackups: %s%s\n' "$LGREEN" "$BUILD_LOG" "$VERSION_LOG" "$BACKUP_DIR"
    printf '%s\n' "$NC"
}

main() {
    init_style
    if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
        printf 'Usage: bash openvas-upgrade.sh\nEdit FORCE_*_VERSION settings to pin releases; blank selects latest stable.\nRun as the normal sudo-enabled account used by the installer.\n'
        return
    fi
    (( $# == 0 )) || die "Unknown argument: $1 (use --help)."
    [[ $EUID -ne 0 ]] || die 'Run this script as your normal sudo-enabled user, not root.'
    local tool
    for tool in sudo curl python3 psql systemctl dpkg stat tar rsync flock; do
        command -v "$tool" >/dev/null || die "Required existing host tool missing: $tool"
    done
    [[ -x "$PYTHON_BIN" ]] || die "Python is missing: $PYTHON_BIN"
    [[ "$SYNC_FEEDS" == true || "$SYNC_FEEDS" == false ]] || die 'SYNC_FEEDS must be true or false.'
    [[ "$KEEP_BUILD_FILES" == true || "$KEEP_BUILD_FILES" == false ]] || die 'KEEP_BUILD_FILES must be true or false.'
    [[ "$SERVICE_CHECK_SECONDS" =~ ^[0-9]+$ ]] || die 'SERVICE_CHECK_SECONDS must be an integer.'
    validate_progress_interval
    [[ "$INSTALL_PREFIX" == /* && "$INSTALL_PREFIX" != / ]] || die 'INSTALL_PREFIX must be an absolute installation directory.'
    set -Ee -o pipefail
    umask 077
    mkdir -p "$WORK_ROOT" "$BUILD_LOG_DIR"
    exec 9> "$WORK_ROOT/upgrade.lock"
    flock -n 9 || die "Another upgrade is using $WORK_ROOT."
    RUN_DIR=$(mktemp -d "$WORK_ROOT/run-$(date +%Y%m%d-%H%M%S)-XXXXXX")
    BUILD_ID="${RUN_DIR##*/}"
    SOURCE_DIR="$RUN_DIR/source"
    BUILD_DIR="$RUN_DIR/build"
    INSTALL_DIR="$RUN_DIR/install"
    BACKUP_DIR="$RUN_DIR/backup"
    BUILD_LOG="$BUILD_LOG_DIR/$BUILD_ID-upgrade.log"
    VERSION_LOG="$BUILD_LOG_DIR/$BUILD_ID-versions.env"
    mkdir "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"
    : > "$BUILD_LOG"
    : > "$VERSION_LOG"
    # Work/backup directories and logs stay private, while installed program data
    # needs normal readable file and directory modes for the gvm service account.
    umask 022
    trap cleanup EXIT
    trap 'upgrade_failed "$?" "$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    start_sudo_keepalive
    start_logging
    export PATH="$SERVICE_PATH:$PATH"
    printf '\n%s Itiligent GVM/OpenVAS Appliance Upgrader\n                    %sPowered by Greenbone%s\n\n%s' \
        "$GREYB" "$LGREENB" "$GREY" "$NC"
    printf 'Upgrade log: %s\nWorking directory: %s\n' "$BUILD_LOG" "$RUN_DIR"
    perform_upgrade
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
