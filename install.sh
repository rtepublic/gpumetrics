#!/usr/bin/env bash
# filepath: /home/krisz/gitprojects/gpumetrics_github/install.sh

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
   echo "This script must be run as root" 
   exit 1
fi

# Default values
TAG=""
USE_CURL=false
USE_WGET=false

# Parse command line arguments
while getopts "t:h" opt; do
  case $opt in
    t)
      TAG="$OPTARG"
      ;;
    h)
      echo "Usage: $0 [-t TAG]"
      echo "  -t TAG    Install from specific tag (default: main branch)"
      echo "  -h        Show this help message"
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      echo "Use -h for help"
      exit 1
      ;;
  esac
done

# Check if curl exists
if command -v curl &> /dev/null; then
  USE_CURL=true
  DL_COMMAND="curl -s -o"
fi

if ! $USE_CURL; then
  # Check if wget exists
  if command -v wget &> /dev/null; then
    USE_WGET=true
    DL_COMMAND="wget --quiet -O"
  fi
fi

if ! $USE_CURL && ! $USE_WGET; then
  echo "ERROR: Neither curl nor wget is installed. Please install one of them to proceed."
  exit 1
fi

set_permissions() {
    chmod 750 /usr/local/bin/gpumetrics.sh
    chmod 644 /etc/cron.d/gpumetrics
    chmod 644 /etc/logrotate.d/gpumetrics
    chmod 644 /etc/rsyslog.d/70-gpumetrics.conf
}

download_file() {
    local destination=$1
    local source_url=$2
    local description=$3
    
    $DL_COMMAND "$destination" "$source_url"
    
    if [ ! -f "$destination" ]; then
        echo "ERROR: Failed to install $description."
        exit 1
    fi
}

# Set BASE_URL based on whether a tag was specified
if [ -n "$TAG" ]; then
    BASE_URL="https://raw.githubusercontent.com/rtepublic/gpumetrics/refs/tags/$TAG/artifacts"
    echo "Installing from tag: $TAG"
else
    BASE_URL="https://raw.githubusercontent.com/rtepublic/gpumetrics/refs/heads/main/artifacts"
    echo "Installing from main branch"
fi

# Download files
download_file "/usr/local/bin/gpumetrics.sh" "$BASE_URL/usr/local/bin/gpumetrics.sh" "gpumetrics script"
download_file "/etc/cron.d/gpumetrics" "$BASE_URL/etc/cron.d/gpumetrics" "gpumetrics cron job"
download_file "/etc/logrotate.d/gpumetrics" "$BASE_URL/etc/logrotate.d/gpumetrics" "gpumetrics logrotate job"
download_file "/etc/rsyslog.d/70-gpumetrics.conf" "$BASE_URL/etc/rsyslog.d/70-gpumetrics.conf" "gpumetrics rsyslog configuration"

# Set permissions
set_permissions

# Restart rsyslog service to apply new configuration
if command -v systemctl &> /dev/null; then
    systemctl restart rsyslog
elif command -v service &> /dev/null; then
    service rsyslog restart
else
    echo "WARNING: Could not restart rsyslog service. Please restart it manually."
fi

echo "OK: Installation completed successfully!"