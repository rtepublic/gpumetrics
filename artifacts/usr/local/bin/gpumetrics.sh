#!/usr/bin/env bash

GPU_TYPE=""
ROCM_SMI="/usr/bin/rocm-smi"
NVIDIA_SMI="/usr/bin/nvidia-smi"
TIMEOUT="60"
GPUMETRICS_LOG="/var/log/gpumetrics/gpumetrics.log"
LOGGER="/usr/bin/logger -i -t gpumetrics -p local4.info"
LOGGER_ERR="/usr/bin/logger -i -t gpumetrics -p local4.err"

# GPUMetrics Variables
GPUDriverVersion=""
GPUInstance=""
GPUMemPercentUsed=""
GPUName=""
GPUTemperature=""
GPUTotalRAM=""
GPUUsedRAM=""
GPUUtilPercent=""
GPUUtilPercentAvg=""
GPUPowerDraw=""
GPUPowerCap=""
ReportTime=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
ResourceID=""
TimeGenerated=""

write_error () {
  echo "$1" | $LOGGER_ERR
}

# Root permission check
if [ "$EUID" -ne 0 ]; then
  write_error "This script must be run as root"
  exit 1
fi

if ! command -v curl &> /dev/null; then
  write_error "curl command not found"
  exit 1
fi

is_cloud_environment() {
  timeout 1 bash -c '< /dev/tcp/169.254.169.254/80' > /dev/null 2>&1
  return $?
}

trim() {
  local var="$*"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

write_log() {
  echo "{\"ResourceID\":\"$ResourceID\",\"GPUName\":\"$GPUName\",\"GPUTotalRAM\":$GPUTotalRAM,\"GPUUsedRAM\":$GPUUsedRAM,\"GPUMemPercentUsed\":$GPUMemPercentUsed,\"GPUUtilPercent\":$GPUUtilPercent,\"GPUUtilPercentAvg\":$GPUUtilPercentAvg,\"GPUTemperature\":$GPUTemperature,\"GPUPowerDraw\":$GPUPowerDraw,\"GPUPowerCap\":$GPUPowerCap,\"GPUInstance\":$GPUInstance,\"GPUDriverVersion\":\"$GPUDriverVersion\",\"ReportTime\":\"$ReportTime\"}" | $LOGGER
}

get_nvidia() {
  output=$(timeout $TIMEOUT $NVIDIA_SMI --query-gpu=driver_version,index,utilization.memory,name,temperature.gpu,memory.total,memory.used,utilization.gpu,utilization.gpu,power.draw,power.limit --format=csv,noheader,nounits)
  if [ $? -ne 0 ]; then
    write_error "nvidia-smi command failed - $output"
    exit 1
  fi

  echo "$output" | while IFS=, read -r GPUDriverVersion GPUInstance GPUMemPercentUsed GPUName GPUTemperature GPUTotalRAM GPUUsedRAM GPUUtilPercent GPUUtilPercentAvg GPUPowerDraw GPUPowerCap; do
    GPUName=$(trim "$GPUName")
    GPUTotalRAM=$(trim "$GPUTotalRAM")
    GPUUsedRAM=$(trim "$GPUUsedRAM")
    GPUMemPercentUsed=$(trim "$GPUMemPercentUsed")
    GPUUtilPercent=$(trim "$GPUUtilPercent")
    GPUUtilPercentAvg=$(trim "$GPUUtilPercentAvg")
    GPUTemperature=$(trim "$GPUTemperature")
    GPUPowerDraw=$(trim "$GPUPowerDraw")
    GPUPowerCap=$(trim "$GPUPowerCap")
    GPUInstance=$(trim "$GPUInstance")
    write_log
  done
}

get_amd() {
  # Gather power cap info first using -M
  declare -A AMD_POWER_CAPS
  while read -r line; do
    if [[ "$line" =~ ^GPU\[([0-9]+)\]\ :\ Max\ Graphics\ Package\ Power.*:\ ([0-9.]+)\ W ]]; then
      gpu_index="${BASH_REMATCH[1]}"
      power_cap="${BASH_REMATCH[2]}"
      AMD_POWER_CAPS["$gpu_index"]="$power_cap"
    fi
  done < <($ROCM_SMI -M 2>/dev/null)

  output=$(timeout $TIMEOUT $ROCM_SMI --showmeminfo=vram --showproductname --showtemp --showuse --showpower --csv)
  if [ $? -ne 0 ]; then
    write_error "rocm-smi command failed - $output"
    exit 1
  fi
  
# Convert bytes to MiB for AMD GPU RA metric
  echo "$output" | awk -F',' '
  NR==1 { next }
  /^card/ {
    $7 = sprintf("%.2f", $7 / 1024 / 1024)
    $8 = sprintf("%.2f", $8 / 1024 / 1024)
    print $1","$2","$3","$4","$5","$6","$7","$8","$9","$10","$11","$12","$13","$14","$15","$16","$17
  }' | while IFS=, read -r AMDCARD AMDSensorTemp AMDMemTemp AMDPower AMDGPUUse AMDGFXActivity AMDVRAMTotalMem AMDVRAMTotalUsedMem AMDCardSeries AMDCardModel AMDCardVendor AMDCardSKU AMDSubsystemID AMDDeviceRev AMDNodeId AMDGUID AMDGFXVersion; do

    if [[ "$AMDCARD" == "device" || -z "$AMDCARD" ]]; then
      continue
    fi
    GPUDriverVersion=$AMDGFXVersion
    GPUInstance=$(echo "$AMDCARD" | tr -d "card")
    GPUName="AMD $AMDCardSeries"
    GPUTemperature=$(printf "%.0f" "$AMDSensorTemp")
    GPUTotalRAM=$AMDVRAMTotalMem
    GPUUsedRAM=$AMDVRAMTotalUsedMem
    GPUMemPercentUsed=$(awk "BEGIN {printf \"%d\", ($GPUUsedRAM/$GPUTotalRAM)*100}")
    GPUUtilPercent=$AMDGPUUse
    GPUUtilPercentAvg=$AMDGPUUse
    GPUPowerDraw=$(printf "%.1f" "$AMDPower")
    GPUPowerCap="${AMD_POWER_CAPS[$GPUInstance]:-0}"
    write_log
  done
}

# Resource ID detection
if is_cloud_environment; then
  ResourceID=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01" | sed -n 's/.*"resourceId":"\([^"]*\)".*/\1/p')
elif timeout 1 bash -c '< /dev/tcp/127.0.0.1/40342' > /dev/null 2>&1; then
  export IMDS_ENDPOINT="http://localhost:40342"
  export IDENTITY_ENDPOINT="http://localhost:40342/metadata/identity/oauth2/token"
  ResourceID=$(curl -s -D - -H Metadata:true "http://127.0.0.1:40342/metadata/instance/compute?api-version=2020-06-01" | sed -n 's/.*"resourceId":"\([^"]*\)".*/\1/p')
else
  write_error "Failed to determine if we're an Arc host or not. Unable to determine ResourceId. Exiting."
  exit 1
fi

# Detect GPU type
if [ -x $NVIDIA_SMI ]; then
  GPU_TYPE="NVIDIA"
elif [ -x $ROCM_SMI ]; then
  GPU_TYPE="AMD"
else
  write_error "No valid GPU tools found"
  exit 1
fi

# Collect metrics
if [ "$GPU_TYPE" = "NVIDIA" ]; then
  get_nvidia
elif [ "$GPU_TYPE" = "AMD" ]; then
  get_amd
fi
