#!/bin/bash --login
# ==============================================================================
# CSF3 VS Code Server (Tunnel) Launcher
#
# - Uses `srun` for `-p interactive`
# - Uses `sbatch` for `-p multicore_small` (or any non-interactive partition)
# - Always runs in ~/scratch
#
# Usage on CSF3:
#   ./start_vscode_csf3.sh interactive      # Interactive srun on -p interactive
#   ./start_vscode_csf3.sh multicore_small  # Batch sbatch on -p multicore_small
#
# Optional 2nd and 3rd arguments: [WALLTIME] [CPUS]
#   ./start_vscode_csf3.sh multicore_small 0-2 4
# ==============================================================================

set -e

ARG1="${1:-interactive}"  # Default to 'interactive'
WALLTIME="${2:-0-2}"      # Default 2 hours (format: D-HH or HH:MM:SS, e.g., 0-1, 0-2)
CPUS="${3:-4}"            # Default 4 CPU cores

# Resolve script path before changing directory
SCRIPT_PATH="$(realpath "$0")"

# Always move into scratch directory
if [[ -d "${HOME}/scratch" ]]; then
    cd "${HOME}/scratch"
elif [[ -d "/scratch/${USER}" ]]; then
    cd "/scratch/${USER}"
fi
SCRATCH_DIR="$(pwd -P)"

# Store VS Code CLI and Server data in scratch to avoid filling home quota
export VSCODE_CLI_DATA_DIR="${SCRATCH_DIR}/.vscode-cli"
SERVER_DATA_DIR="${SCRATCH_DIR}/.vscode-server"
mkdir -p "$VSCODE_CLI_DATA_DIR" "$SERVER_DATA_DIR"

# Map argument or shorthand aliases to CSF3 partition and flags
case "$ARG1" in
    interactive|interactve|cpu|i)
        PARTITION="interactive"
        EXTRA_FLAGS=()
        ;;
    multicore_small|multicore|mc|ms)
        PARTITION="multicore_small"
        EXTRA_FLAGS=()
        ;;
    gpu|gpuL)
        PARTITION="gpuL"
        EXTRA_FLAGS=(-G 1)
        ;;
    gpuV|gpuA)
        PARTITION="$ARG1"
        EXTRA_FLAGS=(-G 1)
        ;;
    *)
        PARTITION="$ARG1"
        EXTRA_FLAGS=()
        ;;
esac

# ==============================================================================
# Step 1: On the login node -> launch via srun (if interactive) or sbatch (otherwise)
# ==============================================================================
if [[ -z "$SLURM_JOB_ID" ]]; then
    echo "=================================================================="
    echo "Currently on login node ($(hostname))."
    echo "Working directory : $SCRATCH_DIR"
    echo "Target partition  : -p $PARTITION (cores: $CPUS, walltime: $WALLTIME)"
    echo "=================================================================="

    if [[ "$PARTITION" == "interactive" ]]; then
        echo "Launching interactive session with srun..."
        exec srun -p "$PARTITION" "${EXTRA_FLAGS[@]}" -n "$CPUS" -t "$WALLTIME" --pty bash "$SCRIPT_PATH" "$PARTITION" "$WALLTIME" "$CPUS"
    else
        echo "Submitting batch job with sbatch (since partition is '$PARTITION')..."
        JOB_ID=$(sbatch --parsable \
            -J "vscode_tunnel" \
            -p "$PARTITION" \
            "${EXTRA_FLAGS[@]}" \
            -n "$CPUS" \
            -t "$WALLTIME" \
            -o "${SCRATCH_DIR}/vscode_tunnel_%j.log" \
            "$SCRIPT_PATH" "$PARTITION" "$WALLTIME" "$CPUS")

        LOG_FILE="${SCRATCH_DIR}/vscode_tunnel_${JOB_ID}.log"
        touch "$LOG_FILE"

        echo "Submitted Slurm batch job : $JOB_ID"
        echo "Log file                  : $LOG_FILE"
        echo "To stop the tunnel later  : scancel $JOB_ID"
        echo "------------------------------------------------------------------"
        echo "Streaming $LOG_FILE (wait for job to start and print the login code/URL)."
        echo "NOTE: Pressing Ctrl+C here only stops viewing the log; the sbatch job stays running!"
        echo "=================================================================="
        exec tail -n +1 -f "$LOG_FILE"
    fi
fi

# ==============================================================================
# Step 2: Inside the allocated compute node -> load VS Code and start tunnel
# ==============================================================================
echo "=================================================================="
echo "Allocated Compute Node : $(hostname)"
echo "Partition              : $PARTITION"
echo "Working Directory      : $SCRATCH_DIR"
echo "Slurm Job ID           : $SLURM_JOB_ID"
echo "To stop this job later : scancel $SLURM_JOB_ID"
echo "=================================================================="

# Load recommended CSF3 VS Code module
module load apps/binapps/vscode/1.109.2

# In sbatch (no interactive arrow-key prompt), pre-select GitHub login if not already authenticated
if [[ "$PARTITION" != "interactive" ]]; then
    if ! code tunnel user show >/dev/null 2>&1; then
        echo "Authenticating with GitHub (open https://github.com/login/device and enter the code below)..."
        code tunnel user login --provider github
    fi
fi

# Start the VS Code Tunnel
echo "Starting VS Code Tunnel in $SCRATCH_DIR..."
code tunnel --accept-server-license-terms --no-sleep --server-data-dir "$SERVER_DATA_DIR"
