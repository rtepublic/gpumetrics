#!/usr/bin/env bash

GPU_TYPE=""
ROCM_SMI="/usr/bin/rocm-smi"
NVIDIA_SMI="/usr/bin/nvidia-smi"
TIMEOUT="60"
GPUMETRICS_LOG="/var/log/gpumetrics/gpumetrics.log"
LOGGER="/usr/bin/logger -i -t gpumetrics -p local4.info"
LOGGER_ERR="/usr/bin/logger -i -t gpumetrics -p local4.err"

### GPUMetrics Variables to populate
GPUDriverVersion=""
GPUInstance=""
GPUMemPercentUsed=""
GPUName=""
GPUTemperature=""
GPUTotalRAM=""
GPUUsedRAM=""
GPUUtilPercent=""
GPUUtilPercentAvg=""
ReportTime=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
ResourceID=""
TimeGenerated=""

# Check if the effective user ID is 0 (root)
if [ "$EUID" -ne 0 ]; then
  >&2 echo "This script must be run as root"
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
    # remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

function write_error () {
  echo $1 | $LOGGER_ERR
}

function write_log {
  echo "{\"ResourceID\":\"$ResourceID\",\"GPUName\":\"$GPUName\",\"GPUTotalRAM\":$GPUTotalRAM,\"GPUUsedRAM\":$GPUUsedRAM,\"GPUMemPercentUsed\":$GPUMemPercentUsed,\"GPUUtilPercent\":$GPUUtilPercent,\"GPUUtilPercentAvg\":$GPUUtilPercentAvg,\"GPUTemperature\":$GPUTemperature,\"GPUInstance\":$GPUInstance,\"GPUDriverVersion\":\"$GPUDriverVersion\",\"ReportTime\":\"$ReportTime\"}" | $LOGGER
}

function get_nvidia {
  output=$(timeout $TIMEOUT $NVIDIA_SMI --query-gpu=driver_version,index,utilization.memory,name,temperature.gpu,memory.total,memory.used,utilization.gpu,utilization.gpu --format=csv,noheader,nounits)
  if [ $? -ne 0 ]; then
    write_error "nvidia-smi command failed - $output"
    exit 1
  fi

  echo "$output" | while IFS=, read -r GPUDriverVersion GPUInstance GPUMemPercentUsed GPUName GPUTemperature GPUTotalRAM GPUUsedRAM GPUUtilPercent GPUUtilPercentAvg; do
    GPUName=$(trim "${GPUName}")
    GPUTotalRAM=$(trim "${GPUTotalRAM}")
    GPUUsedRAM=$(trim "${GPUUsedRAM}")
    GPUMemPercentUsed=$(trim "${GPUMemPercentUsed}")
    GPUUtilPercent=$(trim "${GPUUtilPercent}")
    GPUUtilPercentAvg=$(trim "${GPUUtilPercentAvg}")
    GPUTemperature=$(trim "${GPUTemperature}")
    GPUInstance=$(trim "${GPUInstance}")
    write_log
  done
}

function get_amd {
  AMDCARD=""
  AMDSensorTemp=""
  AMDMemTemp=""
  AMDGPUUse=""
  AMDGFXActivity=""
  AMDVRAMTotalMem=""
  AMDVRAMTotalUsedMem=""
  AMDCardSeries=""
  AMDCardModel=""
  AMDCardVendor=""
  AMDCardSKU=""
  AMDSubsystemID=""
  AMDDeviceRev=""
  AMDNodeId=""
  AMDGUID=""
  AMDGFXVersion=""
  output=$(timeout $TIMEOUT $ROCM_SMI --showmeminfo=vram --showproductname --showtemp --showuse --csv)
  if [ $? -ne 0 ]; then
    write_error "rocm-smi command failed - $output"
    exit 1
  fi

  echo "$output" | while IFS=, read -r AMDCARD AMDSensorTemp AMDMemTemp AMDGPUUse AMDGFXActivity AMDVRAMTotalMem AMDVRAMTotalUsedMem AMDCardSeries AMDCardModel AMDCardVendor AMDCardSKU AMDSubsystemID AMDDeviceRev AMDNodeId AMDGUID AMDGFXVersion; do
    # Skip if we have the header, or an empty value
    if [[ "$AMDCARD" == "device" || "$AMDCARD" == "" ]]; then
      continue
    fi
    GPUDriverVersion=$AMDGFXVersion
    GPUInstance=$(echo $AMDCARD | tr -d "card")
    GPUName="AMD $AMDCardSeries"
    GPUTemperature=$(printf "%.0f" "$AMDSensorTemp")
    GPUTotalRAM=$AMDVRAMTotalMem
    GPUUsedRAM=$AMDVRAMTotalUsedMem
    GPUUtilPercent=$AMDGPUUse
    GPUUtilPercentAvg=$AMDGPUUse
    write_log
  done
}

if is_cloud_environment; then
  ResourceID=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01" | sed -n 's/.*"resourceId":"\([^"]*\)".*/\1/p')
# Otherwise see if we're an Arc host
elif $(timeout 1 bash -c '< /dev/tcp/127.0.0.1/40342' > /dev/null 2>&1 ); then
  export IMDS_ENDPOINT="http://localhost:40342"
  export IDENTITY_ENDPOINT="http://localhost:40342/metadata/identity/oauth2/token"
  ResourceID=$(curl -s -D - -H Metadata:true "http://127.0.0.1:40342/metadata/instance/compute?api-version=2020-06-01"|sed -n 's/.*"resourceId":"\([^"]*\)".*/\1/p')
else
  write_error "Failed to determine if we're an Arc host or not. Unable to determine ResourceId. Exiting."
  exit 1
fi

if [ -x $NVIDIA_SMI ];then
  GPU_TYPE="NVIDIA"
elif [ -x $ROCM_SMI ];then
  GPU_TYPE="AMD"
else
  write_error "No valid GPU tools found"
  exit 1
fi

if [ "$GPU_TYPE" = "NVIDIA" ];then
  get_nvidia
fi

if [ "$GPU_TYPE" = "AMD" ];then
  get_amd
fi
