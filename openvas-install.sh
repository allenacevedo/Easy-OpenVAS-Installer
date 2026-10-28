#!/bin/bash
##############################################################################
# Greenbone Vulnerability Manager appliance Install script
# Multi-distro support for Ubuntu, Debian & Raspbian
# David Harrop
# November 2026
# Build dependency fixes: November 2026
##############################################################################

##############################################################################
# EDIT THESE SETTINGS: All custom settings & dependency mgmt between distros 
# is handled in this section. Blank module versions select GitHub's latest 
# stable release. Environment overrides are also supported, for example:
# FORCE_GVMD_VERSION=26.42.0
##############################################################################

## CUSTOM CONFIG SETTINGS ##
DEFAULT_ADMIN_USER="admin"            # Set the GVM default admin account username
DEFAULT_ADMIN_PASS="password"         # Set the GVM default admin account password
SERVER_NAME=""                        # Preferred server hostname (installer will prompt if left blank)
LOCAL_DOMAIN=""                       # Local DNS suffix (defaults to hostname.dns-suffix if left blank)
CERT_DOMAIN=""                        # TLS certificate dns domain (defaults to hostname.dns-suffix if left blank)
CERT_COUNTRY="AU"                     # For TLS cert, 2 character country code only, must not be blank
CERT_STATE="Victoria"                 # For TLS cert, Optional to change, must not be blank
CERT_LOCATION="Melbourne"             # For TLS cert, Optional to change, must not be blank
CERT_ORG="Itiligent"                  # For TLS cert, Optional to change, must not be blank
CERT_OU="SecOps"                      # For TLS cert, Optional to change, must not be blank
CERT_DAYS="3650"                      # For TLS cert, number of days until self signed certificate expiry
CERT_EC_CURVE="prime256v1"            # ECDSA P-256 (256-bit curve).

# FORCE MODULE VERSIONS or use blank "" to automatically download latest
FORCE_GVM_LIBS_VERSION="${FORCE_GVM_LIBS_VERSION:-}"				# see https://github.com/greenbone/gvm-libs
FORCE_GVMD_VERSION="${FORCE_GVMD_VERSION:-}"						# see https://github.com/greenbone/gvmd
FORCE_PG_GVM_VERSION="${FORCE_PG_GVM_VERSION:-}"					# see https://github.com/greenbone/pg-gvm
FORCE_GSA_VERSION="${FORCE_GSA_VERSION:-}"							# see https://github.com/greenbone/gsa
FORCE_GSAD_VERSION="${FORCE_GSAD_VERSION:-}"						# see https://github.com/greenbone/gsad
FORCE_OPENVAS_SMB_VERSION="${FORCE_OPENVAS_SMB_VERSION:-}"			# see https://github.com/greenbone/openvas-smb
FORCE_OPENVAS_SCANNER_VERSION="${FORCE_OPENVAS_SCANNER_VERSION:-}"	# see https://github.com/greenbone/openvas-scanner
FORCE_OSPD_OPENVAS_VERSION="${FORCE_OSPD_OPENVAS_VERSION:-}"		# see https://github.com/greenbone/ospd-openvas
# openvasd and scannerctl use the selected OPENVAS_SCANNER_VERSION source; OSPD is versioned independently.
FORCE_FEED_SYNC_VERSION="${FORCE_FEED_SYNC_VERSION:-}"				# see https://github.com/greenbone/greenbone-feed-sync
FORCE_GVM_TOOLS_VERSION="${FORCE_GVM_TOOLS_VERSION:-}"				# see https://github.com/greenbone/gvm-tools
FORCE_PYTHON_GVM_VERSION="${FORCE_PYTHON_GVM_VERSION:-}"			# see https://github.com/greenbone/python-gvm
FORCE_PYPSRP_CLI_VERSION="${FORCE_PYPSRP_CLI_VERSION:-}"			# see https://github.com/greenbone/pypsrp-cli
FORCE_FEED_RELEASE="${FORCE_FEED_RELEASE:-}"						# Blank: use feed-sync's defaults; set a release to pin.

# INITIAL FEED DOWNLOAD RETRIES
FEED_SYNC_ATTEMPTS="${FEED_SYNC_ATTEMPTS:-3}"			# Total attempts, including the first (1-99).
FEED_SYNC_RETRY_DELAY="${FEED_SYNC_RETRY_DELAY:-60}"	# Seconds between attempts (0-3600).

# BUILD PATHS
PYTHON_BIN="/usr/bin/python3"					# Use the distro Python with matching development headers.
PYTHON_ENV_DIR="/opt/gvm/venvs"					# Separate Python applications from distro packages.
BUILD_LOG_DIR="$HOME/openvas-build-logs"		# Kept after build/source cleanup.
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-0.2}"	# Spinner interval in seconds; fractions are supported.

# OPTIONAL APT CLEANUP
APT_AUTOREMOVE="${APT_AUTOREMOVE:-false}" # true: remove unused APT packages after the build.

# POSTGRESQL VERSION MANAGEMENT
source /etc/os-release
OFFICIAL_POSTGRESQL="false" # Default = false, true = force official Posgresql source repo
case "${VERSION_CODENAME,,}" in
    *bookworm*)
		OFFICIAL_POSTGRESQL="false"
        POSTGRESQL_MAJOR="15"
        ;;

	*noble*)
		OFFICIAL_POSTGRESQL="false"
        POSTGRESQL_MAJOR="16"
        ;;

	*trixie*)
		OFFICIAL_POSTGRESQL="false"
        POSTGRESQL_MAJOR="17"
        ;;

    *)
        OFFICIAL_POSTGRESQL="true" # Default to official source if no disto match
        POSTGRESQL_MAJOR="16"
        ;;
esac
POSTGRESQL=("postgresql-${POSTGRESQL_MAJOR}" "postgresql-server-dev-${POSTGRESQL_MAJOR}")
PG_CONFIG="/usr/lib/postgresql/${POSTGRESQL_MAJOR}/bin/pg_config"


# DEPENDENCY MANAGEMENT (Any changes here must be replicated in the upgrade script)
# common
COMMON_DEPS=(build-essential curl cron cmake pkg-config python3 python3-venv
    python3-dev ca-certificates openssl gnupg wget sudo ufw git iproute2
    libffi-dev libxslt1-dev rsync htop)
# Installed separately to preserve the original APT options and Postfix setup.
MAIL_DEPS=(postfix mailutils)

# gvm-libs
GVMLIBS_DEPS=(libglib2.0-dev libgpgme-dev libgnutls28-dev uuid-dev libhiredis-dev
    libxml2-dev libpcap-dev libnet1-dev libpaho-mqtt-dev libldap-dev libradcli-dev
    xmltoman libcjson-dev libcrypt-dev zlib1g-dev libcurl4-gnutls-dev
    libgcrypt20-dev libssh-dev doxygen graphviz)

# gvmd
GVMD_DEPS1=(libglib2.0-dev libgnutls28-dev libpq-dev "${POSTGRESQL[@]}"
    libical-dev xsltproc rsync libgpgme-dev libcjson-dev libbsd-dev)
GVMD_DEPS2=(texlive-latex-extra texlive-fonts-recommended xmlstarlet zip rpm
    fakeroot dpkg nsis gnupg gpgsm wget sshpass openssh-client socat snmp
    python3 smbclient python3-lxml gnutls-bin)

# pg-gvm
PGGVM_DEPS=(libglib2.0-dev libical-dev "${POSTGRESQL[@]}")

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

# Set colours
GREY="" GREYB="" LGREEN="" LGREENB="" LRED="" LPURPLE="" LPURPLEB="" LYELLOW="" NC=""

# BEGIN INSTALLER PROGRESS DISPLAY
PROGRESS_OWNER_PID=$BASHPID
PROGRESS_PID=""
PROGRESS_LABEL=""
PROGRESS_STARTED=0
PROGRESS_FD=1
PROGRESS_INLINE=false
PROGRESS_TERMINAL=false
OUTPUT_PID=""
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

section() {
    printf '\n%s###############################################################################\n %s\n###############################################################################%s\n\n' \
        "$LGREEN" "$*" "$NC"
}

# Initialize colours before logging redirects stdout, as in the upgrade script.
init_style
PROGRESS_TERMINAL="$PROGRESS_INLINE"

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
    validate_progress_interval
    exec 3>&1 4>&2
    PROGRESS_FD=1
    # Python is installed by COMMON_DEPS on minimal systems. Keep the existing
    # tee logger until it is available, then enable the terminal renderer.
    if [[ "$PROGRESS_TERMINAL" == true && -x "$PYTHON_BIN" ]]; then
        PROGRESS_INLINE=true
        exec > >(terminal_output) 2>&1
    else
        PROGRESS_INLINE=false
        exec > >(tee -a "$BUILD_LOG") 2>&1
    fi
    OUTPUT_PID=$!
}

stop_logging() {
    if [[ -n "$OUTPUT_PID" ]]; then
        exec 1>&3 2>&4
        wait "$OUTPUT_PID" || true
        exec 3>&- 4>&-
        OUTPUT_PID=""
        PROGRESS_INLINE=false
    fi
}

enable_terminal_progress() {
    if [[ "$PROGRESS_TERMINAL" == true && "$PROGRESS_INLINE" != true && -x "$PYTHON_BIN" ]]; then
        stop_logging
        start_logging
    fi
}

progress_loop() {
    local parent_pid="$1" started="$2" label="$3"
    local frames='|/-\' frame=0 elapsed last_plain=0 sleeper=""
    # This helper only reports status; the actual task stays in the main shell.
    # Reap the timer sleep when the display stops.
    trap - ERR EXIT
    trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi' EXIT
    trap 'exit 0' INT TERM HUP
    while kill -0 "$parent_pid" 2>/dev/null; do
        sleep "$PROGRESS_INTERVAL" &
        sleeper=$!
        wait "$sleeper"
        sleeper=""
        elapsed=$((SECONDS - started))
        # A fast animation is useful on a terminal; plain logs need fewer lines.
        if [[ "$PROGRESS_INLINE" == true ]] || (( elapsed - last_plain >= 10 )); then
            print_progress 0 "${LPURPLE}[${frames:frame%${#frames}:1}]${NC} $label [$(elapsed_time "$elapsed") elapsed]" >&"$PROGRESS_FD"
            last_plain=$elapsed
        fi
        frame=$((frame + 1))
    done
}

finish_progress() {
    # Subshell error/exit traps must leave the main shell's reporter alone.
    [[ "$BASHPID" == "$PROGRESS_OWNER_PID" ]] || return 0
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

start_progress() {
    PROGRESS_LABEL="$1"
    PROGRESS_STARTED=$SECONDS
    print_progress 0 "${LPURPLE}[>]${NC} $PROGRESS_LABEL ..."
    progress_loop "$BASHPID" "$PROGRESS_STARTED" "$PROGRESS_LABEL" &
    PROGRESS_PID=$!
}

run_task() {
    local task_status
    start_progress "$1"
    shift
    # Keep the command in this shell: exports, cwd, stdin and errexit survive.
    "$@"
    task_status=$?
    finish_progress "$task_status"
    return "$task_status"
}

installer_exit() {
    local status="${1:-$?}"
    [[ "$BASHPID" == "$PROGRESS_OWNER_PID" ]] || return "$status"
    trap - EXIT
    finish_progress "$status"
    # Preserve the installer's existing sudo refresher shutdown.
    if [[ -n "${sudo_keepalive_pid:-}" ]]; then
        kill "$sudo_keepalive_pid" 2>/dev/null || true
    fi
    stop_logging
    return "$status"
}
# END INSTALLER PROGRESS DISPLAY

# Validate optional cleanup before the installer changes the system.
if [[ "$APT_AUTOREMOVE" != true && "$APT_AUTOREMOVE" != false ]]; then
    printf '%sAPT_AUTOREMOVE must be true or false.%s\n' "$LRED" "$NC" >&2
    exit 1
fi

# Validate retry settings before the installer changes the system.
if [[ ! "$FEED_SYNC_ATTEMPTS" =~ ^[1-9][0-9]?$ ]]; then
    printf '%sFEED_SYNC_ATTEMPTS must be an integer from 1 to 99.%s\n' "$LRED" "$NC" >&2
    exit 1
fi
if [[ ! "$FEED_SYNC_RETRY_DELAY" =~ ^(0|[1-9][0-9]{0,3})$ ]] || (( FEED_SYNC_RETRY_DELAY > 3600 )); then
    printf '%sFEED_SYNC_RETRY_DELAY must be an integer from 0 to 3600 seconds.%s\n' "$LRED" "$NC" >&2
    exit 1
fi

clear

# Make sure the user is NOT running this script as root
if [[ $EUID -eq 0 ]]; then
    echo
    echo -e "${LRED}This script must NOT be run as root, it will prompt for sudo when needed." 1>&2
    echo -e ${NC}
    exit 1
fi

# Check if sudo is installed. (Debian does not always include sudo by default.)
if ! command -v sudo &> /dev/null; then
    echo "${LRED}The sudo package is not installed. Please install sudo."
    echo -e ${NC}
    exit 1
fi

# Make sure the user running this script is a member of the sudo group
if ! id -nG "$USER" | grep -qw "sudo"; then
    echo
    echo -e "${LRED}The current user (${USER}) must be a member of the 'sudo' group & be granted sudo privilages to run this script.${NC}" 1>&2
    exit 1
fi

# Authenticate once and keep sudo active during long builds.
sudo -v || exit 1

installer_pid=$$
(
    while kill -0 "$installer_pid" 2>/dev/null; do
        sudo -n -v || exit 1
        sleep 60
    done
) &
sudo_keepalive_pid=$!

# Stop the refresh loop when the installer exits.
# Check identity before any command in an inherited EXIT trap.
trap 'case "$BASHPID" in "$PROGRESS_OWNER_PID") installer_exit "$?" ;; esac' EXIT

clear

# Script branding header
printf '\n%s Itiligent GVM/OpenVAS Appliance Builder\n                    %sPowered by Greenbone%s\n\n%s' \
    "$GREYB" "$LGREENB" "$GREY" "$NC"

# Set global variables & paths
export INSTALL_PREFIX=/usr/local
export PATH=$INSTALL_PREFIX/bin:$INSTALL_PREFIX/sbin:$PATH
export SOURCE_DIR=$HOME/source
export BUILD_DIR=$HOME/build
export INSTALL_DIR=$HOME/install


# These host tools are used before common build dependencies are installed.
for tool in ip systemctl hostnamectl; do
    command -v "$tool" >/dev/null || { echo "Required host tool missing: $tool" >&2; exit 1; }
done

# Get the default route interface IP address as we need this for TLS certificate creation later
DEFAULT_IP=$(ip addr show $(ip route | awk '/default/ { print $5 }') | grep "inet" | head -n 1 | awk '/inet/ {print $2}' | cut -d'/' -f1)


# An intitial dns suffix is needed as a starting value for the script prompts.
get_domain_suffix() {
    echo "$1" | awk '{print $2}'
}
# Search for "search" & "domain" entries in /etc/resolv.conf
search_line=$(grep -E '^search[[:space:]]+' /etc/resolv.conf)
domain_line=$(grep -E '^domain[[:space:]]+' /etc/resolv.conf)
# Check if both "search" & "domain" lines exist
if [[ -n "$search_line" ]] && [[ -n "$domain_line" ]]; then
    # Both "search" & "domain" lines exist, extract the domain suffix from both
    search_suffix=$(get_domain_suffix "$search_line")
    domain_suffix=$(get_domain_suffix "$domain_line")
    # Print the domain suffix that appears first
    if [[ ${#search_suffix} -lt ${#domain_suffix} ]]; then
        DOMAIN_SUFFIX=$search_suffix
    else
        DOMAIN_SUFFIX=$domain_suffix
    fi
elif [[ -n "$search_line" ]]; then
    # If only "search" line exists
    DOMAIN_SUFFIX=$(get_domain_suffix "$search_line")
elif [[ -n "$domain_line" ]]; then
    # If only "domain" line exists
    DOMAIN_SUFFIX=$(get_domain_suffix "$domain_line")
else
    # If no "search" or "domain" lines found
    DOMAIN_SUFFIX="local"
fi

# GVM user setup & use this action to trigger our initial sudo prompt
sudo useradd -r -M -U -G sudo -s /usr/sbin/nologin gvm
sudo usermod -aG gvm $USER

# Clean up anything from a previously halted install
sudo systemctl stop gsad gvmd ospd-openvas openvasd &>/dev/null
cd ~
sudo rm -rf $SOURCE_DIR &>/dev/null
sudo rm -rf $INSTALL_DIR &>/dev/null
sudo rm -rf $BUILD_DIR &>/dev/null
sudo rm -f /etc/openvas/openvas.conf &>/dev/null
sudo rm -f /etc/redis/redis-openvas.conf &>/dev/null
sudo sed -i '/gvm/d' /etc/sudoers &>/dev/null

# Create build directories
mkdir -p $SOURCE_DIR
mkdir -p $BUILD_DIR
mkdir -p $INSTALL_DIR
echo


##############################################################################
# Install menu prompts
##############################################################################

# Consistent /etc/hosts & domain suffix values are needed for TLS implementation. The below approach allows the user
# to either hit enter at the prompt to keep current hostname & DNS values, or enter new values for both.

# Ensure SERVER_NAME is consistent with local host entries
if [[ -z ${SERVER_NAME} ]]; then
    echo -e "${LPURPLEB} Update Linux system HOSTNAME? [Enter to keep: ${HOSTNAME}]${GREYB}"
    read -p "              Enter Linux hostname : " SERVER_NAME
    # If hit enter making no SERVER_NAME change, assume the existing hostname as current
    if [[ "${SERVER_NAME}" = "" ]]; then
        SERVER_NAME=$HOSTNAME
    fi
    echo
    # A SERVER_NAME was derived via the prompt
    # Apply the SERVER_NAME value & remove & update any old 127.0.1.1 localhost references
    $(sudo hostnamectl set-hostname $SERVER_NAME &>/dev/null &) &>/dev/null
	sleep 1
    sudo sed -i '/127.0.1.1/d' /etc/hosts &>>/dev/null
    echo '127.0.1.1       '${SERVER_NAME}'' | sudo tee -a /etc/hosts &>>/dev/null
    $(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
else
    echo
    # A SERVER_NAME value was derived from a pre-set script variable
    # Apply the SERVER_NAME value & remove & update any old 127.0.1.1 localhost references
    $(sudo hostnamectl set-hostname $SERVER_NAME &>/dev/null &) &>/dev/null
	sleep 1
    sudo sed -i '/127.0.1.1/d' /etc/hosts &>>/dev/null
    echo '127.0.1.1       '${SERVER_NAME}'' | sudo tee -a /etc/hosts &>>/dev/null
    $(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
fi

# Ensure LOCAL_DOMAIN suffix & localhost entries are consistent
if [[ -z ${LOCAL_DOMAIN} ]]; then
    echo -e "${LPURPLEB} Update Linux LOCAL DNS SUFFIX [Enter to keep: ${SERVER_NAME}.${DOMAIN_SUFFIX}]${GREYB}"
    read -p "              Complete this local domain suffix: $SERVER_NAME." LOCAL_DOMAIN
    # If hit enter making no LOCAL_DOMAIN name change, assume the existing domain suffix as current
    if [[ "${LOCAL_DOMAIN}" = "" ]]; then
        LOCAL_DOMAIN=$DOMAIN_SUFFIX
    fi
    echo
    # A LOCAL_DOMAIN value was derived via the prompt
    # Removes any old localhost & resolv file values & update these with the new LOCAL_DOMAIN value
	$(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
	sleep 1
    sudo sed -i "/${DEFAULT_IP}/d" /etc/hosts
    sudo sed -i '/domain/d' /etc/resolv.conf
    sudo sed -i '/search/d' /etc/resolv.conf
    # Refresh the /etc/hosts file with the server name & new local domain value
    echo ''${DEFAULT_IP}'	'${SERVER_NAME}.${LOCAL_DOMAIN} ${SERVER_NAME}'' | sudo tee -a /etc/hosts &>>/dev/null
    # Refresh /etc/resolv.conf with new domain & search suffix values
    echo 'domain	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>>/dev/null
    echo 'search	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>>/dev/null
    $(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
else
    echo
    # A LOCAL_DOMIN value was derived from a pre-set script variable
    # Remove any old localhost & resolv file values & update these with the new LOCAL_DOMAIN value
	$(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
	sleep 1
    sudo sed -i "/${DEFAULT_IP}/d" /etc/hosts
    sudo sed -i '/domain/d' /etc/resolv.conf
    sudo sed -i '/search/d' /etc/resolv.conf
    # Refresh the /etc/hosts file with the server name & new local domain value
    echo ''${DEFAULT_IP}'	'${SERVER_NAME}.${LOCAL_DOMAIN} ${SERVER_NAME}'' | sudo tee -a /etc/hosts &>>/dev/null
    # Refresh /etc/resolv.conf with new domain & search suffix values
    echo 'domain	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>>/dev/null
    echo 'search	'${LOCAL_DOMAIN}'' | sudo tee -a /etc/resolv.conf &>>/dev/null
    $(sudo systemctl restart systemd-hostnamed &>/dev/null &) &>/dev/null
fi

# Now that $SERVER_NAME & $LOCAL_DOMAIN values are updated, both values are merged to create
# a local FQDN value (used in the default TLS certificate config & file name)
DEFAULT_FQDN=$SERVER_NAME.$LOCAL_DOMAIN

# If the TLS domain name is not manually overridden at the prompt, keep the default FQDN as the TLS domain name
if [ -z "${CERT_DOMAIN}" ]; then
    CERT_DOMAIN="${DEFAULT_FQDN}"
fi

echo -e "${LPURPLEB} GVM web console admin account name [Enter to use: ${DEFAULT_ADMIN_USER}]${GREYB}"
# Prompt for managment console admin acount username
  read -r -p "              Enter admin account name: " admin_user
  ADMIN_USER=${admin_user:-$DEFAULT_ADMIN_USER}

# Secure prompt for password with confirmation
  while true; do
     read -r -s -p "              Enter admin user password: " password
     echo
     read -r -s -p "              Confirm admin user password: " password_confirm
     echo
      if [ "${password}" == "${password_confirm}" ]; then
         ADMIN_PASS=${password:-$DEFAULT_ADMIN_PASS}
         break
     else
         echo "              Passwords do not match. Please try again."
         echo
     fi
done


# Build dependency helpers. Failures keep the build tree and a private log.
die() {
    finish_progress 1
    printf '\n%s\n' "$*" >&2
    exit 1
}

build_failed() {
    local status="$1" line="$2"
    trap - ERR
    finish_progress "$status"
    printf '\nBuild failed at line %s (exit %s).\nLog: %s\nBuild sources have been retained.\n' \
        "$line" "$status" "$BUILD_LOG" >&2
    exit "$status"
}

download_source() {
    local component="$1" version="$2" signature="${3:-}"
    local archive="$SOURCE_DIR/$component-$version.tar.gz"
    curl -f -L --retry 3 "https://github.com/greenbone/$component/archive/refs/tags/v$version.tar.gz" -o "$archive"
    if [[ -n "$signature" ]]; then
        curl -f -L --retry 3 "https://github.com/greenbone/$component/releases/download/v$version/$signature" -o "$archive.asc"
        gpg --verify "$archive.asc" "$archive"
    fi
    tar -C "$SOURCE_DIR" -xzf "$archive"
}

install_python_app() {
    local name="$1" compiler build_path="$PATH"
    shift
    local venv="$PYTHON_ENV_DIR/$name"
    # A real compiler path also lets root-run pip build Rust extensions on ARM,
    # without asking root's Rustup to find the invoking user's toolchain.
    if [[ -x "$HOME/.cargo/bin/rustup" ]] && compiler=$("$HOME/.cargo/bin/rustup" which rustc 2>/dev/null); then
        build_path="$(dirname "$compiler"):$build_path"
    fi
    sudo "$PYTHON_BIN" -m venv --clear "$venv"
    sudo env PATH="$venv/bin:$build_path" "$venv/bin/python" -m pip install --upgrade pip
    sudo env PATH="$venv/bin:$build_path" "$venv/bin/python" -m pip install "$@"
    "$venv/bin/python" -m pip check
    "$venv/bin/python" -m pip list --format=freeze > "$BUILD_LOG_DIR/$BUILD_ID-$name-requirements.txt"
}

prepare_native_archives() {
    local scanner="$1" krb5_version pcap_version part archive
    local krb5_prefix="$BUILD_DIR/openvas-static/krb5"
    local pcap_prefix="$BUILD_DIR/openvas-static/pcap"
    # Use the dependency sources and versions shipped with this scanner tag.
    krb5_version=$(sed -n 's/^ARG KRB5_VERSION=\([0-9][0-9.]*\)$/\1/p' "$scanner/.docker/prod.Dockerfile")
    pcap_version=$(sed -n 's/^ARG LIBPCAP_VERSION=\([0-9][0-9.]*\)$/\1/p' "$scanner/.docker/prod.Dockerfile")
    [[ -n "$krb5_version" && -n "$pcap_version" ]] || die "Scanner source does not declare the expected native dependency versions."
    [[ -x "$scanner/.docker/vendor/krb5-$krb5_version/src/configure" ]] || die "Vendored MIT Kerberos source is missing."
    [[ -x "$scanner/.docker/vendor/libpcap-$pcap_version/configure" ]] || die "Vendored libpcap source is missing."

    (
        cd "$scanner/.docker/vendor/krb5-$krb5_version/src"
        ./configure --prefix="$krb5_prefix" --enable-static --disable-shared \
            --without-system-verto --without-libedit --without-keyutils --disable-rpath
        # Build only the library subtrees, as in upstream's archive preparation.
        for part in util/support util/et util/profile include lib/crypto lib/krb5 lib/gssapi; do
            make -C "$part" -j"$(nproc)"
        done
        make install-mkdirs
        for part in util/support util/et util/profile include lib/crypto lib/krb5 lib/gssapi; do
            make -C "$part" install
        done
    )
    (
        cd "$scanner/.docker/vendor/libpcap-$pcap_version"
        # Prevent host-installed optional capture backends adding static link dependencies.
        ./configure --prefix="$pcap_prefix" --disable-shared --disable-dbus \
            --without-libnl --disable-usb --disable-bluetooth --disable-rdma
        make -j"$(nproc)"
        make install
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

sync_feeds_and_start_services() {
    # Keep download retries and service startup in one authenticated sudo session.
    sudo bash -e -s -- "$INSTALL_PREFIX/bin/greenbone-feed-sync" \
        "${FORCE_FEED_RELEASE:-}" "$FEED_SYNC_ATTEMPTS" "$FEED_SYNC_RETRY_DELAY" \
        "$BUILD_LOG" "$LYELLOW" "$LRED" "$NC" <<'FEED_STARTUP'
feed_command=("$1")
[[ -z "$2" ]] || feed_command+=(--feed-release "$2")
attempts="$3" retry_delay="$4" build_log="$5"
yellow="$6" red="$7" reset="$8"
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

for ((attempt = 1; attempt <= attempts; attempt++)); do
    # Repair existing files in place: replacing a lock file would break locking.
    # Repeat before every attempt, since feed-sync drops privileges to gvm.
    for lock in /var/lib/openvas/feed-update.lock /var/lib/gvm/feed-update.lock; do
        if [[ -L "$lock" || ( -e "$lock" && ! -f "$lock" ) ]]; then
            printf '%sInvalid feed lock file: %s%s\n' "$red" "$lock" "$reset" >&2
            exit 1
        fi
        if [[ -f "$lock" ]]; then
            chown gvm:gvm "$lock"
            chmod 0660 "$lock"
        fi
    done

    printf '%sFeed download attempt %s/%s. Details: %s%s\n' \
        "$yellow" "$attempt" "$attempts" "$build_log" "$reset"
    # Keep feed type/URL and error details in the build log, leaving the shared
    # elapsed-time spinner on screen. --fail-fast still stops each failed attempt.
    if "${feed_command[@]}" --fail-fast >>"$build_log" 2>&1; then
        break
    else
        status=$?
    fi
    case "$status" in 129|130|143) exit "$status" ;; esac
    if (( attempt == attempts )); then
        printf '%sFeed download failed after %s attempts (exit %s). Log: %s%s\n' \
            "$red" "$attempts" "$status" "$build_log" "$reset" >&2
        exit "$status"
    fi
    printf '%sFeed download failed (exit %s); retrying in %s seconds.%s\n' \
        "$yellow" "$status" "$retry_delay" "$reset"
    sleep "$retry_delay"
done

systemctl start ospd-openvas
systemctl start gvmd
systemctl start gsad
systemctl start openvasd
sleep 15
systemctl stop gsad
chown -R gvm:gvm /var/log/gvm
systemctl start gsad
FEED_STARTUP
}
# End build dependency helpers.

mkdir -p -m 700 "$BUILD_LOG_DIR" || exit 1
BUILD_ID="$(date +%Y%m%d-%H%M%S)-$$"
BUILD_LOG="$BUILD_LOG_DIR/$BUILD_ID-install.log"
VERSION_LOG="$BUILD_LOG_DIR/$BUILD_ID-versions.env"
(umask 077; : > "$BUILD_LOG"; : > "$VERSION_LOG") || exit 1
start_logging
printf 'Build log: %s\n' "$BUILD_LOG"
set -Ee -o pipefail
trap 'build_failed "$?" "$LINENO"' ERR

section "Updating Linux OS"
spin() {
    local pid="$1"
    start_progress "${2:-Working}"
    # The caller retains its existing wait and error handling for this job.
    while kill -0 "$pid" 2>/dev/null; do
        sleep "$PROGRESS_INTERVAL"
    done
}

(
	# Update Linux base
    sudo apt-get update >>"$BUILD_LOG" 2>&1
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -qq

    # Add the official Postgresql source repo
    if [[ "${OFFICIAL_POSTGRESQL}" == "true" ]]; then
        sudo apt-get -y install lsb-release ca-certificates wget >>"$BUILD_LOG" 2>&1
        sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
        sudo wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo tee /etc/apt/trusted.gpg.d/apt.postgresql.org.asc >/dev/null
        sudo apt-get update -qq >>"$BUILD_LOG" 2>&1
    fi

) &
pid=$!
spin "$pid" "Updating Linux OS"
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo
echo -e "${LGREEN}Linux updated successfully...${NC}"


section "Installing common dependencies"

(
    # Install common dependencies
    sudo apt-get install --no-install-recommends --assume-yes "${COMMON_DEPS[@]}" >>"$BUILD_LOG" 2>&1
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${MAIL_DEPS[@]}" >>"$BUILD_LOG" 2>&1
    sudo service postfix restart >>"$BUILD_LOG" 2>&1
	# Import the Greenbone Community Signing Key
    curl -f -L https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc
    gpg --import /tmp/GBCommunitySigningKey.asc
    echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust

) &
pid=$!
spin "$pid" "Installing common dependencies..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo
echo -e "${LGREEN}Common dependencies installed successfully...${NC}"
enable_terminal_progress

# Preserve existing root mail routing; otherwise deliver locally to the installer account.
root_alias=$(sudo awk 'tolower($0) ~ /^[[:space:]]*root[[:space:]]*:/ { print }' /etc/aliases)
if [[ -z "$root_alias" ]]; then
    printf '\nroot: %s\n' "$(id -un)" | sudo tee -a /etc/aliases >/dev/null
    run_task "Updating local administrative mail aliases" sudo newaliases
fi


section "Checking latest OpenVAS GitHub releases - edit script to force a version"
get_latest_release() {
    local response
    response=$(curl -f -sS -L --retry 3 "https://api.github.com/repos/$1/releases/latest") || return
    "$PYTHON_BIN" -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])' <<< "$response"
}

declare -A repos=(
    [GVM_LIBS_VERSION]="greenbone/gvm-libs"
    [GVMD_VERSION]="greenbone/gvmd"
    [PG_GVM_VERSION]="greenbone/pg-gvm"
    [GSA_VERSION]="greenbone/gsa"
    [GSAD_VERSION]="greenbone/gsad"
    [OPENVAS_SMB_VERSION]="greenbone/openvas-smb"
    [OPENVAS_SCANNER_VERSION]="greenbone/openvas-scanner"
    [OSPD_OPENVAS_VERSION]="greenbone/ospd-openvas"
    [FEED_SYNC_VERSION]="greenbone/greenbone-feed-sync"
    [GVM_TOOLS_VERSION]="greenbone/gvm-tools"
    [PYTHON_GVM_VERSION]="greenbone/python-gvm"
    [PYPSRP_CLI_VERSION]="greenbone/pypsrp-cli"
)

echo -e " ${LGREEN}Selected OpenVAS package releases:${NC}"
start_progress "Checking selected OpenVAS releases"
for version in "${!repos[@]}"; do
    forced="FORCE_$version"
    if [[ -n "${!forced}" ]]; then
        latest_version="${!forced}"
    else
        latest_version=$(get_latest_release "${repos[$version]}")
    fi
    latest_version="${latest_version#v}"
    [[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || die "Invalid release version for ${repos[$version]}: $latest_version"
    printf -v "$version" '%s' "$latest_version"
    export "$version"
    echo " $version=$latest_version"
    printf 'FORCE_%s=%s\n' "$version" "$latest_version" >> "$VERSION_LOG"
done
finish_progress "$?"
export OPENVAS_DAEMON="$OPENVAS_SCANNER_VERSION"
printf 'POSTGRESQL_MAJOR=%s\n' "$POSTGRESQL_MAJOR" >> "$VERSION_LOG"
printf 'APT_AUTOREMOVE=%s\n' "$APT_AUTOREMOVE" >> "$VERSION_LOG"
printf 'FEED_SYNC_ATTEMPTS=%s\nFEED_SYNC_RETRY_DELAY=%s\n' "$FEED_SYNC_ATTEMPTS" "$FEED_SYNC_RETRY_DELAY" >> "$VERSION_LOG"

# Use feed-sync's defaults unless a feed release is explicitly forced.
# Share this command between the initial sync and the daily cron job.
FEED_COMMAND="$INSTALL_PREFIX/bin/greenbone-feed-sync"

if [[ -n "${FORCE_FEED_RELEASE:-}" ]]; then
    [[ "$FORCE_FEED_RELEASE" =~ ^[0-9]+\.[0-9]+$ ]] ||
        die "Invalid feed release: $FORCE_FEED_RELEASE"

    FEED_COMMAND+=" --feed-release $FORCE_FEED_RELEASE"
fi

# Record the requested override; blank means no script-level override.
printf 'FORCE_FEED_RELEASE=%s\n' "${FORCE_FEED_RELEASE:-}" >> "$VERSION_LOG"

multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
export PKG_CONFIG_PATH="$INSTALL_PREFIX/lib/pkgconfig:$INSTALL_PREFIX/lib/$multiarch/pkgconfig:$INSTALL_PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
printf '%s\n' "$INSTALL_PREFIX/lib" "$INSTALL_PREFIX/lib64" | sudo tee /etc/ld.so.conf.d/gvm-local.conf >/dev/null
"$PYTHON_BIN" --version
cmake --version
cc --version
printf 'BUILD_OS=%q\nBUILD_ARCH=%q\n' "$PRETTY_NAME" "$multiarch" >> "$VERSION_LOG"


section "Building & installing gvm-libs $GVM_LIBS_VERSION"

(
    # Install dependencies
    sudo apt-get install -y "${GVMLIBS_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing gvm-libs dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}gvm-libs dependencies installed successfully...${NC}"
echo

# Download the gvm-libs sources
export GVM_LIBS_VERSION=$GVM_LIBS_VERSION
run_task "Downloading gvm-libs sources" curl -f -L https://github.com/greenbone/gvm-libs/archive/refs/tags/v$GVM_LIBS_VERSION.tar.gz -o $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz
run_task "Downloading gvm-libs signature" curl -f -L https://github.com/greenbone/gvm-libs/releases/download/v$GVM_LIBS_VERSION/gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc -o $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc
run_task "Verifying the gvm-libs signature" gpg --verify $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz

# Build gvm-libs
echo
run_task "Extracting gvm-libs sources" tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz
mkdir -p $BUILD_DIR/gvm-libs && cd $BUILD_DIR/gvm-libs
run_task "Configuring gvm-libs" cmake $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var
run_task "Compiling gvm-libs" make -j$(nproc)

# Install gvm-libs
mkdir -p $INSTALL_DIR/gvm-libs
run_task "Staging gvm-libs" make DESTDIR=$INSTALL_DIR/gvm-libs install
# Follow existing destination directory links, including /lib -> /usr/lib.
run_task "Installing gvm-libs" sudo rsync -rlv --keep-dirlinks "$INSTALL_DIR/gvm-libs/" /
sudo ldconfig


echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Building & installing gvmd $GVMD_VERSION"

(
    # Install dependencies
    sudo apt-get install -y "${GVMD_DEPS1[@]}" >>"$BUILD_LOG" 2>&1
    sudo apt-get install -y --no-install-recommends "${GVMD_DEPS2[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing gvmd dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}gvmd dependencies installed successfully..${NC}"
echo

# Download the gvm-libs sources
export GVM_LIBS_VERSION=$GVM_LIBS_VERSION
run_task "Downloading gvmd sources" curl -f -L https://github.com/greenbone/gvmd/archive/refs/tags/v$GVMD_VERSION.tar.gz -o $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz
run_task "Downloading gvmd signature" curl -f -L https://github.com/greenbone/gvmd/releases/download/v$GVMD_VERSION/gvmd-$GVMD_VERSION.tar.gz.asc -o $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz.asc
run_task "Verifying the gvmd signature" gpg --verify $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz.asc $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz

# Use headers and extension paths for the selected PostgreSQL server.
[[ -x "$PG_CONFIG" ]] || die "Missing PostgreSQL development tool: $PG_CONFIG"
"$PG_CONFIG" --version
server_version=$(sudo -Hiu postgres psql -X -At -c 'SHOW server_version_num;')
[[ "$server_version" =~ ^[0-9]+$ ]] || die "Cannot determine the default PostgreSQL server version."
(( server_version / 10000 == POSTGRESQL_MAJOR )) || die "Default PostgreSQL cluster does not match PostgreSQL $POSTGRESQL_MAJOR headers. Select the matching cluster before continuing."

# Build gvmd
echo
run_task "Extracting gvmd sources" tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz
mkdir -p $BUILD_DIR/gvmd && cd $BUILD_DIR/gvmd
run_task "Configuring gvmd" cmake $SOURCE_DIR/gvmd-$GVMD_VERSION \
  -DPG_CONFIG_EXECUTABLE="$PG_CONFIG" \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DLOCALSTATEDIR=/var \
  -DSYSCONFDIR=/etc \
  -DGVM_DATA_DIR=/var \
  -DGVMD_RUN_DIR=/run/gvmd \
  -DOPENVAS_DEFAULT_SOCKET=/run/ospd/ospd-openvas.sock \
  -DGVM_FEED_LOCK_PATH=/var/lib/gvm/feed-update.lock \
  -DSYSTEMD_SERVICE_DIR=/lib/systemd/system \
  -DLOGROTATE_DIR=/etc/logrotate.d
run_task "Compiling gvmd" make -j$(nproc)

# Install gvmd
mkdir -p $INSTALL_DIR/gvmd
run_task "Staging gvmd" make DESTDIR=$INSTALL_DIR/gvmd install
run_task "Installing gvmd" sudo rsync -rlv --keep-dirlinks "$INSTALL_DIR/gvmd/" /
cat << EOF > $BUILD_DIR/gvmd.service
[Unit]
Description=Greenbone Vulnerability Manager daemon (gvmd)
After=network.target networking.service postgresql.service ospd-openvas.service
Wants=postgresql.service ospd-openvas.service
Documentation=man:gvmd(8)
ConditionKernelCommandLine=!recovery

[Service]
Type=exec
User=gvm
Group=gvm
PIDFile=/run/gvmd/gvmd.pid
RuntimeDirectory=gvmd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/sbin/gvmd --foreground --osp-vt-update=/run/ospd/ospd-openvas.sock --listen-group=gvm
Restart=always
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo cp -v $BUILD_DIR/gvmd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable gvmd


echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Building & installing pg-gvm $PG_GVM_VERSION"

(
    # Install dependencies
    sudo apt-get install -y "${PGGVM_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing pg-gvm dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}pg-gvm dependencies installed successfully...${NC}"
echo

# Download the pg-gvm sources
export PG_GVM_VERSION=$PG_GVM_VERSION
run_task "Downloading pg-gvm sources" curl -f -L https://github.com/greenbone/pg-gvm/archive/refs/tags/v$PG_GVM_VERSION.tar.gz -o $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz
run_task "Downloading pg-gvm signature" curl -f -L https://github.com/greenbone/pg-gvm/releases/download/v$PG_GVM_VERSION/pg-gvm-$PG_GVM_VERSION.tar.gz.asc -o $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz.asc
run_task "Verifying the pg-gvm signature" gpg --verify $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz.asc $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz

# Build pg-gvm
echo
run_task "Extracting pg-gvm sources" tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz
mkdir -p $BUILD_DIR/pg-gvm && cd $BUILD_DIR/pg-gvm
run_task "Configuring pg-gvm" cmake $SOURCE_DIR/pg-gvm-$PG_GVM_VERSION \
  -DPGCONFIG="$PG_CONFIG" \
  -DCMAKE_BUILD_TYPE=Release
run_task "Compiling pg-gvm" make -j$(nproc)

# Install pg-gvm
mkdir -p $INSTALL_DIR/pg-gvm
run_task "Staging pg-gvm" make DESTDIR=$INSTALL_DIR/pg-gvm install
run_task "Installing pg-gvm" sudo rsync -rlv --keep-dirlinks "$INSTALL_DIR/pg-gvm/" /
sudo ldconfig


echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Building & installing gsa $GSA_VERSION"
    export GSA_VERSION=$GSA_VERSION
    run_task "Downloading gsa sources" curl -f -L https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz -o $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz
    run_task "Downloading gsa signature" curl -f -L https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz.asc -o $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz.asc
    run_task "Verifying the gsa signature" gpg --verify $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz.asc $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz

    # Extract & install gsa
    echo
    mkdir -p $SOURCE_DIR/gsa-$GSA_VERSION
    run_task "Extracting gsa sources" tar -C $SOURCE_DIR/gsa-$GSA_VERSION -xvzf $SOURCE_DIR/gsa-$GSA_VERSION.tar.gz
    sudo mkdir -p $INSTALL_PREFIX/share/gvm/gsad/web/
    run_task "Installing GSA web assets" sudo cp -rvf $SOURCE_DIR/gsa-$GSA_VERSION/* $INSTALL_PREFIX/share/gvm/gsad/web/


echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Building & installing gsad, adding certificates for https:443 console access"

(
    # Install dependencies
    sudo apt-get install -y "${GSAD_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing gsad dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}gsad dependencies installed successfully...${NC}"
echo

# Start TLS certificate creation - remove this for http only
DIR_TLS_CERT="/etc/gvm/certs"   # GVM default certificate location
DIR_TLS_KEY="/etc/gvm/private"  # GVM default certificate location
cd ~
run_task "Preparing the TLS certificate directory" sudo install -d -o root -g root -m 0755 "$DIR_TLS_CERT"
run_task "Preparing the TLS private key directory" sudo install -d -o root -g gvm -m 0750 "$DIR_TLS_KEY"
cat <<EOF | tee cert_attributes.txt
[req]
distinguished_name  = req_distinguished_name
x509_extensions     = v3_req
prompt              = no
string_mask         = utf8only

[req_distinguished_name]
C                   = $CERT_COUNTRY
ST                  = $CERT_STATE
L                   = $CERT_LOCATION
O                   = $CERT_ORG
OU                  = $CERT_OU
CN                  = *.$(echo $CERT_DOMAIN | cut -d. -f2-)

[v3_req]
keyUsage            = nonRepudiation, digitalSignature
extendedKeyUsage    = serverAuth, clientAuth, codeSigning, emailProtection
subjectAltName      = @alt_names

[alt_names]
DNS.1               = $CERT_DOMAIN
DNS.2               = *.$(echo $CERT_DOMAIN | cut -d. -f2-)
IP.1                = $DEFAULT_IP
EOF
echo
run_task "Generating the TLS certificate" openssl req -x509 -nodes -newkey ec \
    -pkeyopt "ec_paramgen_curve:$CERT_EC_CURVE" -pkeyopt ec_param_enc:named_curve -sha256 \
    -keyout "$CERT_DOMAIN.key" -out "$CERT_DOMAIN.crt" -days "$CERT_DAYS" -config cert_attributes.txt
# Now create a PFX formatted certificate for easier import to Windows hosts
run_task "Exporting the Windows TLS certificate" sudo openssl pkcs12 -export -out $CERT_DOMAIN.pfx -inkey $CERT_DOMAIN.key -in $CERT_DOMAIN.crt -password pass:1234

# Copy new certification output files to a dedicated location & set their acccess permissions
sudo mv "$CERT_DOMAIN.crt" "$DIR_TLS_CERT/$CERT_DOMAIN.crt"
sudo mv "$CERT_DOMAIN.pfx" "$DIR_TLS_CERT/$CERT_DOMAIN.pfx"
sudo mv "$CERT_DOMAIN.key" "$DIR_TLS_KEY/$CERT_DOMAIN.key"
sudo chown root:root "$DIR_TLS_CERT/$CERT_DOMAIN.crt" "$DIR_TLS_CERT/$CERT_DOMAIN.pfx"
sudo chown root:gvm "$DIR_TLS_KEY/$CERT_DOMAIN.key"
sudo chmod 0644 "$DIR_TLS_CERT/$CERT_DOMAIN.crt"
sudo chmod 0600 "$DIR_TLS_CERT/$CERT_DOMAIN.pfx"
sudo chmod 0640 "$DIR_TLS_KEY/$CERT_DOMAIN.key"
# End TLS certificate creation

# Download gsad sources
echo
export GSAD_VERSION=$GSAD_VERSION
run_task "Downloading gsad sources" curl -f -L https://github.com/greenbone/gsad/archive/refs/tags/v$GSAD_VERSION.tar.gz -o $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz
run_task "Downloading gsad signature" curl -f -L https://github.com/greenbone/gsad/releases/download/v$GSAD_VERSION/gsad-$GSAD_VERSION.tar.gz.asc -o $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz.asc
run_task "Verifying the gsad signature" gpg --verify $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz.asc $SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz

# Build gsad
echo
run_task "Extracting gsad sources" tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz"

# Fix HTTPS redirects to use --port (443), rather than --rport (80).
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

mkdir -p "$BUILD_DIR/gsad" && cd "$BUILD_DIR/gsad"
run_task "Configuring gsad" cmake "$SOURCE_DIR/gsad-$GSAD_VERSION" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var \
  -DGVMD_RUN_DIR=/run/gvmd \
  -DGSAD_RUN_DIR=/run/gsad \
  -DLOGROTATE_DIR=/etc/logrotate.d

run_task "Compiling gsad" make -j"$(nproc)"

# Install gsad
mkdir -p $INSTALL_DIR/gsad
run_task "Staging gsad" make DESTDIR=$INSTALL_DIR/gsad install
run_task "Installing gsad" sudo rsync -rlv --keep-dirlinks "$INSTALL_DIR/gsad/" /

cat << EOF > $BUILD_DIR/gsad.service
[Unit]
Description=Greenbone Security Assistant daemon (gsad)
Documentation=man:gsad(8) https://www.greenbone.net
After=network.target gvmd.service
Wants=gvmd.service

[Service]
Type=exec
#User=gvm
#Group=gvm
RuntimeDirectory=gsad
RuntimeDirectoryMode=2775
PIDFile=/run/gsad/gsad.pid
ExecStart=/usr/local/sbin/gsad --listen=0.0.0.0 --foreground --drop-privileges=gvm --port=443 --rport=80 -c $DIR_TLS_CERT/$CERT_DOMAIN.crt -k $DIR_TLS_KEY/$CERT_DOMAIN.key
# ExecStart=/usr/local/sbin/gsad --foreground --listen=127.0.0.1 --port=9392 --http-only # Swap this line for http only. Change to 0.0.0.0 to bind with all interfaces
Restart=always
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
Alias=greenbone-security-assistant.service
EOF
sudo cp -v $BUILD_DIR/gsad.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable gsad

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Building & installing openvas-smb $OPENVAS_SMB_VERSION"

(
    # Install dependencies
    sudo apt-get install -y "${OPENVASSMB_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing openvas-smb dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}openvas-smb dependencies installed successfully...${NC}"
echo

# Download the openvas-smb sources
export OPENVAS_SMB_VERSION=$OPENVAS_SMB_VERSION
run_task "Downloading openvas-smb sources" curl -f -L https://github.com/greenbone/openvas-smb/archive/refs/tags/v$OPENVAS_SMB_VERSION.tar.gz -o $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz
run_task "Downloading openvas-smb signature" curl -f -L https://github.com/greenbone/openvas-smb/releases/download/v$OPENVAS_SMB_VERSION/openvas-smb-v$OPENVAS_SMB_VERSION.tar.gz.asc -o $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz.asc
run_task "Verifying the openvas-smb signature" gpg --verify $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz.asc $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz

# Build openvas-smb
echo
run_task "Extracting openvas-smb sources" tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz
mkdir -p $BUILD_DIR/openvas-smb && cd $BUILD_DIR/openvas-smb
run_task "Configuring openvas-smb" cmake $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release
run_task "Compiling openvas-smb" make -j$(nproc)

# Install openvas-smb
mkdir -p $INSTALL_DIR/openvas-smb
run_task "Staging openvas-smb" make DESTDIR=$INSTALL_DIR/openvas-smb install
run_task "Installing openvas-smb" sudo rsync -rlv --keep-dirlinks "$INSTALL_DIR/openvas-smb/" /
sudo ldconfig


echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Building & installing openvas-scanner $OPENVAS_SCANNER_VERSION"

(
    # Install dependencies
    sudo apt-get install -y "${OPENVASSCAN_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing openvas-scanner dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}openvas-scanner dependencies installed successfully...${NC}"
echo

# Download openvas-scanner sources
export OPENVAS_SCANNER_VERSION=$OPENVAS_SCANNER_VERSION
run_task "Downloading openvas-scanner sources" curl -f -L https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_SCANNER_VERSION.tar.gz -o $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz
run_task "Downloading openvas-scanner signature" curl -f -L https://github.com/greenbone/openvas-scanner/releases/download/v$OPENVAS_SCANNER_VERSION/openvas-scanner-v$OPENVAS_SCANNER_VERSION.tar.gz.asc -o $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz.asc
run_task "Verifying the openvas-scanner signature" gpg --verify $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz.asc $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz

# Build openvas-scanner
echo
run_task "Extracting openvas-scanner sources" tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz
mkdir -p $BUILD_DIR/openvas-scanner && cd $BUILD_DIR/openvas-scanner
run_task "Configuring openvas-scanner" cmake $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc \
  -DLOCALSTATEDIR=/var \
  -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock \
  -DOPENVAS_RUN_DIR=/run/ospd
run_task "Compiling openvas-scanner" make -j$(nproc)

# Install openvas-scanner
mkdir -p $INSTALL_DIR/openvas-scanner
run_task "Staging openvas-scanner" make DESTDIR=$INSTALL_DIR/openvas-scanner install
run_task "Installing openvas-scanner" sudo rsync -rlv --keep-dirlinks "$INSTALL_DIR/openvas-scanner/" /
sudo ldconfig
printf "table_driven_lsc = yes\n" | sudo tee /etc/openvas/openvas.conf
sudo printf "openvasd_server = http://127.0.0.1:3000\n" | sudo tee -a /etc/openvas/openvas.conf


echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Building & installing ospd-openvas $OSPD_OPENVAS_VERSION"

(
    # Install dependencies
    sudo apt-get install -y "${OSPD_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing ospd-openvas dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}ospd-openvas dependencies installed successfully...${NC}"
echo

# Download ospd-openvas sources
export OSPD_OPENVAS_VERSION=$OSPD_OPENVAS_VERSION
run_task "Downloading ospd-openvas sources" curl -f -L https://github.com/greenbone/ospd-openvas/archive/refs/tags/v$OSPD_OPENVAS_VERSION.tar.gz -o $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz
run_task "Downloading ospd-openvas signature" curl -f -L https://github.com/greenbone/ospd-openvas/releases/download/v$OSPD_OPENVAS_VERSION/ospd-openvas-v$OSPD_OPENVAS_VERSION.tar.gz.asc -o $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz.asc
run_task "Verifying the ospd-openvas signature" gpg --verify $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz.asc $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz

# Install ospd-openvas
echo
run_task "Extracting ospd-openvas sources" tar -C $SOURCE_DIR -xvzf $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz
cd $SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION
run_task "Installing ospd-openvas and Python dependencies" install_python_app ospd-openvas "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION"
sudo ln -sfn "$PYTHON_ENV_DIR/ospd-openvas/bin/ospd-openvas" "$INSTALL_PREFIX/bin/ospd-openvas"
# --version constructs the daemon before Redis/log permissions are configured.
"$PYTHON_ENV_DIR/ospd-openvas/bin/ospd-openvas" --help >/dev/null
"$PYTHON_ENV_DIR/ospd-openvas/bin/python" -c 'from importlib.metadata import version; print("ospd-openvas " + version("ospd-openvas"))'
cat << EOF > $BUILD_DIR/ospd-openvas.service
[Unit]
Description=OSPd Wrapper for the OpenVAS Scanner (ospd-openvas)
Documentation=man:ospd-openvas(8) man:openvas(8)
After=network.target networking.service redis-server@openvas.service openvasd.service
Wants=redis-server@openvas.service openvasd.service
ConditionKernelCommandLine=!recovery

[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=ospd
RuntimeDirectoryMode=2775
PIDFile=/run/ospd/ospd-openvas.pid
Environment="PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/usr/local/bin/ospd-openvas --foreground --unix-socket /run/ospd/ospd-openvas.sock --pid-file /run/ospd/ospd-openvas.pid --log-file /var/log/gvm/ospd-openvas.log --lock-file-dir /var/lib/openvas --socket-mode 0o770 --notus-feed-dir /var/lib/notus/advisories
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
sudo cp -vf $BUILD_DIR/ospd-openvas.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ospd-openvas

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Building & installing openvasd $OPENVAS_DAEMON"

(
    # Install dependencies
    sudo apt-get install -y "${OPENVASD_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing openvasd dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}openvasd dependencies installed successfully...${NC}"

# Install Rustup only if absent; the source's rust-toolchain.toml selects Rust.
if [[ ! -x "$HOME/.cargo/bin/rustup" ]]; then
    run_task "Downloading Rustup" curl --proto '=https' --tlsv1.2 -f -sS -L --retry 3 https://sh.rustup.rs -o "$BUILD_DIR/rustup-init.sh"
    run_task "Installing Rustup" sh "$BUILD_DIR/rustup-init.sh" -y --profile minimal --no-modify-path
fi
source "$HOME/.cargo/env"
echo "openvasd rust dependencies installed successfully..."
echo

# openvasd and scannerctl use the already verified scanner source tree.
scanner_source="$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION"
if [[ -f "$scanner_source/rust/crates/nasl-c-lib/libopenvas-krb5-sys/build.rs" ]]; then
    run_task "Building static Kerberos and libpcap libraries" prepare_native_archives "$scanner_source"
fi
cd "$scanner_source/rust"
if [[ -f rust-toolchain.toml ]]; then
    rust_toolchain=$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' rust-toolchain.toml)
    [[ "$rust_toolchain" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]] || die "Cannot read the scanner's Rust toolchain."
    run_task "Preparing the scanner Rust toolchain" rustup toolchain install "$rust_toolchain" --profile minimal
    # Override inherited Rustup settings for this build only.
    export RUSTUP_TOOLCHAIN="$rust_toolchain"
fi
rustc --version
cargo --version
printf 'RUST_VERSION=%q\nCARGO_VERSION=%q\n' "$(rustc --version)" "$(cargo --version)" >> "$VERSION_LOG"
[[ -f Cargo.lock ]] || die "The scanner release does not contain Cargo.lock."
BIN_VERSION="$OPENVAS_SCANNER_VERSION" run_task "Compiling openvasd and scannerctl" cargo build --locked --release --bin openvasd --bin scannerctl --target-dir "$BUILD_DIR/openvasd-target"
run_task "Installing openvasd" sudo install -m 755 "$BUILD_DIR/openvasd-target/release/openvasd" "$INSTALL_PREFIX/bin/openvasd"
run_task "Installing scannerctl" sudo install -m 755 "$BUILD_DIR/openvasd-target/release/scannerctl" "$INSTALL_PREFIX/bin/scannerctl"

# Windows PSRP is a separate runtime helper, with its own Python dependency set.
start_progress "Installing Windows helper dependencies"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${PYPSRP_DEPS[@]}" >>"$BUILD_LOG" 2>&1
finish_progress "$?"
# Upstream does not publish a detached signature for this helper's releases.
run_task "Downloading and verifying pypsrp-cli" download_source pypsrp-cli "$PYPSRP_CLI_VERSION"
windows_packages=("$SOURCE_DIR/pypsrp-cli-$PYPSRP_CLI_VERSION")
# Some distro Impacket wrappers reference missing example files. Keep a working
# distro command; otherwise install both Windows helpers in the isolated env.
if ! sudo -u gvm env PATH=/usr/local/bin:/usr/bin:/bin impacket-wmiexec -h >>"$BUILD_LOG" 2>&1; then
    windows_packages+=(impacket)
fi
run_task "Installing pypsrp-cli and Python dependencies" install_python_app pypsrp-cli "${windows_packages[@]}"
sudo ln -sfn "$PYTHON_ENV_DIR/pypsrp-cli/bin/pypsrp-cli" "$INSTALL_PREFIX/bin/pypsrp-cli"
if (( ${#windows_packages[@]} > 1 )); then
    impacket_command="$PYTHON_ENV_DIR/pypsrp-cli/bin/impacket-wmiexec"
    [[ -x "$impacket_command" ]] || impacket_command="$PYTHON_ENV_DIR/pypsrp-cli/bin/wmiexec.py"
    [[ -x "$impacket_command" ]] || die "The Impacket environment did not install a WMI command."
    sudo ln -sfn "$impacket_command" "$INSTALL_PREFIX/bin/impacket-wmiexec"
fi
sudo -u gvm env PATH=/usr/local/bin:/usr/bin:/bin pypsrp-cli --help >/dev/null
sudo -u gvm env PATH=/usr/local/bin:/usr/bin:/bin impacket-wmiexec -h >/dev/null

cat << EOF > $BUILD_DIR/openvasd.service
[Unit]
Description=OpenVASD
Documentation=https://github.com/greenbone/openvas-scanner/tree/main/rust/openvasd
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
RuntimeDirectory=openvasd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/bin/openvasd --mode service_notus --products /var/lib/notus/products --advisories /var/lib/notus/advisories --listening 127.0.0.1:3000
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
EOF
sudo cp -v $BUILD_DIR/openvasd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable openvasd

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Setting up greenbone-feed-sync"

(
    # Install dependencies
    sudo apt-get install -y "${FEED_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing greenbone-feed-sync dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}greenbone-feed-sync dependencies installed successfully...${NC}"

# Install greenbone-feed-sync
run_task "Downloading and verifying greenbone-feed-sync" download_source greenbone-feed-sync "$FEED_SYNC_VERSION" "greenbone-feed-sync-$FEED_SYNC_VERSION.tar.gz.asc"
run_task "Installing greenbone-feed-sync and Python dependencies" install_python_app greenbone-feed-sync "$SOURCE_DIR/greenbone-feed-sync-$FEED_SYNC_VERSION"
for command in greenbone-feed-sync greenbone-nvt-sync greenbone-scapdata-sync greenbone-certdata-sync; do
    sudo ln -sfn "$PYTHON_ENV_DIR/greenbone-feed-sync/bin/$command" "$INSTALL_PREFIX/bin/$command"
done
"$PYTHON_ENV_DIR/greenbone-feed-sync/bin/greenbone-feed-sync" --version


echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Setting up gvm-tools"

(
# Install dependencies
sudo apt-get install -y "${GVMTOOLS_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing gvm-tools dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}gvm-tools dependencies installed successfully...${NC}"

# Install gvm-tools
run_task "Downloading and verifying python-gvm" download_source python-gvm "$PYTHON_GVM_VERSION" "python-gvm-$PYTHON_GVM_VERSION.tar.gz.asc"
run_task "Downloading and verifying gvm-tools" download_source gvm-tools "$GVM_TOOLS_VERSION" "gvm-tools-$GVM_TOOLS_VERSION.tar.gz.asc"
run_task "Installing gvm-tools and Python dependencies" install_python_app gvm-tools "$SOURCE_DIR/python-gvm-$PYTHON_GVM_VERSION" "$SOURCE_DIR/gvm-tools-$GVM_TOOLS_VERSION"
for command in gvm-cli gvm-script gvm-pyshell; do
    sudo ln -sfn "$PYTHON_ENV_DIR/gvm-tools/bin/$command" "$INSTALL_PREFIX/bin/$command"
done
"$PYTHON_ENV_DIR/gvm-tools/bin/gvm-cli" --help >/dev/null


echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Setting up the Redis data store"

(
    # Install dependencies
    sudo apt-get install -y "${REDIS_DEPS[@]}" >>"$BUILD_LOG" 2>&1
) &
pid=$!
spin "$pid" "Installing redis dependency packages..."
if wait "$pid"; then
    rc=0
else
    rc=$?
fi
finish_progress "$rc"

if (( rc != 0 )); then
  echo -e "${LRED}Task failed (exit $rc)${NC}"
  exit "$rc"
fi

echo -e "${LGREEN}redis dependencies installed successfully...${NC}"

# Verify the installed executable/library dependencies before configuring services.
sudo ldconfig
"$INSTALL_PREFIX/sbin/openvas" --version
"$INSTALL_PREFIX/sbin/gvmd" --version
"$INSTALL_PREFIX/sbin/gsad" --version
"$INSTALL_PREFIX/bin/openvasd" --version
"$INSTALL_PREFIX/bin/scannerctl" --help >/dev/null
# Keep strict error handling active through configuration and service checks.
echo "Build log: $BUILD_LOG"
echo "Resolved versions: $VERSION_LOG"

# Configure redis
sudo cp $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION/config/redis-openvas.conf /etc/redis/
sudo chown redis:redis /etc/redis/redis-openvas.conf
echo "db_address = /run/redis-openvas/redis.sock" | sudo tee -a /etc/openvas/openvas.conf
sudo systemctl start redis-server@openvas.service
sudo systemctl enable redis-server@openvas.service
sudo usermod -aG redis gvm


echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Setting up Postgres db, gvm file permissions & importing feed signature."
# Setup GVM directories & permissions
sudo mkdir -p /var/lib/notus
sudo mkdir -p /run/gvmd
run_task "Setting permissions on /var/lib/gvm" sudo chown -R gvm:gvm /var/lib/gvm
run_task "Setting permissions on /var/lib/openvas" sudo chown -R gvm:gvm /var/lib/openvas
run_task "Setting permissions on /var/lib/notus" sudo chown -R gvm:gvm /var/lib/notus
run_task "Setting permissions on /var/log/gvm" sudo chown -R gvm:gvm /var/log/gvm
run_task "Setting permissions on /run/gvmd" sudo chown -R gvm:gvm /run/gvmd
run_task "Setting permissions on /var/lib/gvm" sudo chmod -R g+srw /var/lib/gvm
run_task "Setting permissions on /var/lib/openvas" sudo chmod -R g+srw /var/lib/openvas
run_task "Setting permissions on /var/log/gvm" sudo chmod -R g+srw /var/log/gvm

# Set gvmd executable permissions
sudo chown gvm:gvm /usr/local/sbin/gvmd
sudo chmod 6750 /usr/local/sbin/gvmd

# Import the update feed's digital signature
run_task "Downloading the Greenbone signing key" curl -f -L https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc
export GNUPGHOME=/tmp/openvas-gnupg
mkdir -p "$GNUPGHOME"
chmod 0700 "$GNUPGHOME"
gpg --import /tmp/GBCommunitySigningKey.asc
echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust
export OPENVAS_GNUPG_HOME=/etc/openvas/gnupg
sudo mkdir -p $OPENVAS_GNUPG_HOME
run_task "Installing the feed signing key" sudo cp -rfv /tmp/openvas-gnupg/* $OPENVAS_GNUPG_HOME/
run_task "Setting permissions on $OPENVAS_GNUPG_HOME" sudo chown -R gvm:gvm $OPENVAS_GNUPG_HOME
sudo chmod 0700 "$OPENVAS_GNUPG_HOME"

# Set sudo permissions on the gvm service account
sudo sh -c "echo '%gvm ALL = NOPASSWD: /usr/local/sbin/openvas' >> /etc/sudoers"

# Set up the gvm PostgreSQL user & database
run_task "Creating the GVM PostgreSQL user" sudo -Hiu postgres createuser -DRS gvm
run_task "Creating the GVMD database" sudo -Hiu postgres createdb -O gvm gvmd
run_task "Configuring the GVM database role" sudo -Hiu postgres psql gvmd -c "create role dba with superuser noinherit; grant dba to gvm;"
sudo ldconfig

# Create the GVM admin user
run_task "Creating the GVM administrator" sudo /usr/local/sbin/gvmd --create-user="$ADMIN_USER" --password="$ADMIN_PASS"

# Set the GVM feed import owner to the GVM admin user
admin_uuid=$(sudo /usr/local/sbin/gvmd --get-users --verbose |
    "$PYTHON_BIN" -c '
import sys
import uuid

matches = []
for line in sys.stdin:
    fields = line.rstrip("\r\n").rsplit(None, 1)
    if len(fields) == 2 and fields[0] == sys.argv[1]:
        matches.append(fields[1])
if len(matches) != 1:
    raise SystemExit("Expected exactly one UUID for the selected GVM administrator.")
try:
    uuid.UUID(matches[0])
except ValueError:
    raise SystemExit("The selected GVM administrator has an invalid UUID.")
print(matches[0])
' "$ADMIN_USER")
run_task "Setting the feed import owner" sudo /usr/local/sbin/gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value "$admin_uuid"

echo -e ${LGREEN}
# read -p "Press enter to continue" # (use this for debugging)
echo -e ${NC}
section "Cleaning up build sources & setting firewall rules"
# Clean up GVM build files
cd ~
run_task "Removing temporary sources" sudo rm -rf $SOURCE_DIR
run_task "Removing temporary staging files" sudo rm -rf $INSTALL_DIR
run_task "Removing temporary build files" sudo rm -rf $BUILD_DIR
rm cert_attributes.txt
sudo rm -f /tmp/GBCommunitySigningKey.asc
if [[ "$APT_AUTOREMOVE" == true ]]; then
    run_task "Removing unused APT packages" sudo apt-get autoremove -qq -y
else
    printf '%sSkipping APT autoremove (APT_AUTOREMOVE=false).%s\n' "$LYELLOW" "$NC"
fi
echo

# Update ufw rules & stop fw log chatter
sudo ufw default allow outgoing
sudo ufw default deny incoming
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
echo "y" | sudo ufw enable >/dev/null
sudo ufw logging off

section "Setting up a random daily cron schedule for feed updates"
# Schedule a random daily feed update time
HOUR=$(shuf -i 0-23 -n 1)
MINUTE=$(shuf -i 0-59 -n 1)
if sudo env LC_ALL=C crontab -l >cron_1 2>cron_1.err; then
    :
else
    cron_status=$?
    if [[ "$cron_status" == 1 && "$(<cron_1.err)" == "no crontab for root" ]]; then
        : >cron_1
    else
        cat cron_1.err >&2
        die "Cannot read root's crontab; the existing schedule has not been replaced."
    fi
fi
if [[ -s cron_1.err ]]; then cat cron_1.err >&2; fi
# Remove any previously added feed update schedules
sudo sed -i '/greenbone-feed-sync/d' cron_1
echo "${MINUTE} ${HOUR} * * * $FEED_COMMAND --quiet" >>cron_1
run_task "Installing the daily feed update schedule" sudo crontab cron_1 ||
    die "Could not install root's feed update schedule."
rm cron_1 cron_1.err
echo -e "Feed update scheduled daily at ${HOUR}:${MINUTE}"

section "A feed update is required before OpenVAS can start, THIS MAY TAKE A LONG TIME"

# Update GVM & start the services
# Keep retries and startup in one sudo session so a long feed update cannot interrupt startup for authentication.
# Also includes a privs fix becasue gsad is started with --drop-privileges (allowing binding to port 443), this results in gsad.log
# being initially created with the wrong privs on 1st startup.
# Detailed feed output goes to the build log while the shared elapsed-time spinner remains visible.

run_task "Synchronizing feeds and starting OpenVAS services" sync_feeds_and_start_services ||
    die "Feed synchronization or service startup failed. Log: $BUILD_LOG"
for service in redis-server@openvas ospd-openvas openvasd gvmd gsad; do
    run_task "Checking $service.service" sudo systemctl is-active --quiet "$service.service" ||
        die "OpenVAS service check failed: $service.service"
done
stop_logging

# Display client certificate import instructions using the shared palette.
section "Windows client certificate import"
printf '%sSave these instructions before continuing.%s\n\n' "$LYELLOW" "$NC"
printf '1. Copy %s%s/%s.crt%s to a location accessible by Windows.\n' \
    "$GREYB" "$DIR_TLS_CERT" "$CERT_DOMAIN" "$NC"
printf '2. From that folder, run PowerShell as Administrator:\n\n'
printf 'Import-Certificate -FilePath ".\\%s.crt" -CertStoreLocation "Cert:\\LocalMachine\\Root"\n' \
    "$CERT_DOMAIN"

section "Linux client certificate import (Chrome/Chromium)"
printf '%sSave these instructions before continuing.%s\n\n' "$LYELLOW" "$NC"
printf '1. Copy %s%s/%s.crt%s to your Linux desktop computer.\n' \
    "$GREYB" "$DIR_TLS_CERT" "$CERT_DOMAIN" "$NC"
printf '2. Install certutil using the command for your distribution:\n\n'
printf '%s\n' 'Debian/Ubuntu: sudo apt-get install libnss3-tools'
printf '%s\n' 'Fedora:        sudo dnf install nss-tools'
printf '\n3. From the folder containing the CRT, run these commands as your normal desktop user:\n\n'
printf 'CERT_NAME="%s"\n' "$CERT_DOMAIN"

cat <<'CLIENT_CERT_COMMANDS'
NSSDB="$HOME/.local/share/pki/nssdb"
if [ -f "$HOME/.pki/nssdb/cert9.db" ]; then
    NSSDB="$HOME/.pki/nssdb"
fi

mkdir -p "$NSSDB"
if [ ! -f "$NSSDB/cert9.db" ]; then
    certutil -N -d "sql:$NSSDB"
fi

# Replace any previous certificate using this nickname.
if certutil -L -d "sql:$NSSDB" -n "$CERT_NAME" >/dev/null 2>&1; then
    certutil -D -d "sql:$NSSDB" -n "$CERT_NAME"
fi

certutil -A -a -d "sql:$NSSDB" -t "P,," \
    -n "$CERT_NAME" -i "./$CERT_NAME.crt"
CLIENT_CERT_COMMANDS

printf '\nRestart your browser after importing the certificate.\n'
printf '%s\n' "$NC"

# Final change password message
section "OpenVAS build complete"
printf 'Management console: %shttps://%s%s\n' "$GREYB" "$CERT_DOMAIN" "$NC"
printf 'Username: %s%s%s\n' "$GREYB" "$ADMIN_USER" "$NC"
printf 'Password: %s%s%s\n\n' "$GREYB" "$ADMIN_PASS" "$NC"
printf '%sYou may change the admin password with:%s\n' "$LPURPLEB" "$NC"
printf 'sudo /usr/local/sbin/gvmd --user=%s --new-password=password\n' "$DEFAULT_ADMIN_USER"
printf '%s\n' "$NC"
