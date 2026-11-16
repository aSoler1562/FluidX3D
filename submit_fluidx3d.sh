#!/bin/bash --login
# ==============================================================================
# CSF3 Unified GPU / CPU Batch Submission Script for FluidX3D
#
# Stages the compiled binary (`bin/FluidX3D`), `stl/` folder, and a snapshot of
# `src/setup_barbs.cpp` + `src/defines.hpp` into:
#   ~/scratch/FLUIDX3D_MICRO_LBM/<CASE_NAME>/
# so that each case is self-contained, can run concurrently in the queue without
# overwriting binaries, and writes exports to:
#   ~/scratch/FLUIDX3D_MICRO_LBM/<CASE_NAME>/bin/export/
#
# Usage (from anywhere):
#   ./submit_fluidx3d.sh <MODE> <CASE_NAME> [WALLTIME] [CPUS]
#
# Examples:
#   ./submit_fluidx3d.sh gpu dx_1um                # GPU on -p gpuL -> ~/scratch/FLUIDX3D_MICRO_LBM/dx_1um/
#   ./submit_fluidx3d.sh gpuV dx_0p5um 08:00:00 4  # V100 GPU, 8h, 4 cores -> .../dx_0p5um/
#   ./submit_fluidx3d.sh cpu mesh_test             # CPU on -p multicore -> .../mesh_test/
#   ./submit_fluidx3d.sh multicore_small test_v2   # CPU on -p multicore_small -> .../test_v2/
# ==============================================================================

set -e

MODE="${1:-gpu}"
CASE_NAME="${2:-default}"

# Locate source repository (supports ~/FLUIDX3D_MICRO_LBM, ~/FLUID3D_MICRO_LBM, or script dir)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "${SCRIPT_DIR}/bin/FluidX3D" ]]; then
    SRC_DIR="$SCRIPT_DIR"
elif [[ -f "${HOME}/FLUIDX3D_MICRO_LBM/bin/FluidX3D" ]]; then
    SRC_DIR="${HOME}/FLUIDX3D_MICRO_LBM"
elif [[ -f "${HOME}/FLUID3D_MICRO_LBM/bin/FluidX3D" ]]; then
    SRC_DIR="${HOME}/FLUID3D_MICRO_LBM"
else
    echo "Error: Could not find compiled bin/FluidX3D. Run 'make Linux -j4' first."
    exit 1
fi

# Locate scratch directory
if [[ -d "${HOME}/scratch" ]]; then
    SCRATCH_ROOT="$(cd "${HOME}/scratch" && pwd -P)"
elif [[ -d "/scratch/${USER}" ]]; then
    SCRATCH_ROOT="/scratch/${USER}"
else
    echo "Error: Could not find ~/scratch or /scratch/${USER}."
    exit 1
fi

RUN_DIR="${SCRATCH_ROOT}/FLUIDX3D_MICRO_LBM/${CASE_NAME}"

# Map mode/partition argument to CSF3 Slurm partition, GPU flags, and default cores
case "$MODE" in
    gpu|gpuL)
        PARTITION="gpuL"
        EXTRA_FLAGS=(--gres=gpu:1)
        DEFAULT_CPUS=4
        DEFAULT_TIME="04:00:00"
        ;;
    gpuV|gpuA|gpuA40GB|gpuH_short)
        PARTITION="$MODE"
        EXTRA_FLAGS=(--gres=gpu:1)
        DEFAULT_CPUS=4
        DEFAULT_TIME="04:00:00"
        ;;
    cpu|multicore|mc)
        PARTITION="multicore"
        EXTRA_FLAGS=()
        DEFAULT_CPUS=16
        DEFAULT_TIME="12:00:00"
        ;;
    multicore_small|ms)
        PARTITION="multicore_small"
        EXTRA_FLAGS=()
        DEFAULT_CPUS=4
        DEFAULT_TIME="04:00:00"
        ;;
    *)
        PARTITION="$MODE"
        EXTRA_FLAGS=()
        DEFAULT_CPUS=4
        DEFAULT_TIME="04:00:00"
        ;;
esac

WALLTIME="${3:-$DEFAULT_TIME}"
CPUS="${4:-$DEFAULT_CPUS}"

# ==============================================================================
# Step 1: When run from terminal -> stage files into CASE_NAME & submit sbatch
# ==============================================================================
if [[ -z "$SLURM_JOB_ID" ]]; then
    mkdir -p "${RUN_DIR}/bin/export" "${RUN_DIR}/stl" "${RUN_DIR}/src_snapshot"

    if [[ "$SRC_DIR" != "$RUN_DIR" ]]; then
        echo "Staging case '$CASE_NAME' from $SRC_DIR -> $RUN_DIR ..."
        cp -f "${SRC_DIR}/bin/FluidX3D" "${RUN_DIR}/bin/FluidX3D"
        cp -rf "${SRC_DIR}/stl/"* "${RUN_DIR}/stl/"
        # Save a snapshot of setup_barbs.cpp and defines.hpp for version tracking
        cp -f "${SRC_DIR}/src/setup_barbs.cpp" "${SRC_DIR}/src/defines.hpp" "${RUN_DIR}/src_snapshot/" 2>/dev/null || true
    fi
    cp -f "$0" "${RUN_DIR}/submit_fluidx3d.sh"

    cd "$RUN_DIR"
    JOB_ID=$(sbatch --parsable \
        -J "fx3d_${CASE_NAME}" \
        -p "$PARTITION" \
        "${EXTRA_FLAGS[@]}" \
        -n "$CPUS" \
        -t "$WALLTIME" \
        -o "${RUN_DIR}/fluidx3d_%j.log" \
        "${RUN_DIR}/submit_fluidx3d.sh" "$MODE" "$CASE_NAME" "$WALLTIME" "$CPUS")

    echo "=================================================================="
    echo "Submitted FluidX3D Job ID : $JOB_ID"
    echo "Case Name                 : $CASE_NAME"
    echo "Mode / Partition          : $MODE (-p $PARTITION ${EXTRA_FLAGS[*]})"
    echo "CPU Cores / Walltime      : $CPUS cores, $WALLTIME"
    echo "Case Run Directory        : $RUN_DIR"
    echo "Results & VTK Export Dir  : ${RUN_DIR}/bin/export/"
    echo "Config Snapshot Saved In  : ${RUN_DIR}/src_snapshot/"
    echo "Log File                  : ${RUN_DIR}/fluidx3d_${JOB_ID}.log"
    echo "Monitor with              : tail -f ${RUN_DIR}/fluidx3d_${JOB_ID}.log"
    echo "=================================================================="
    exit 0
fi

# ==============================================================================
# Step 2: Inside the Slurm batch job on the compute node
# ==============================================================================
cd "$RUN_DIR"

echo "=================================================================="
echo "Slurm Job ID      : $SLURM_JOB_ID"
echo "Case Name         : $CASE_NAME"
echo "Compute Node      : $(hostname)"
echo "Partition         : $PARTITION"
echo "Working Directory : $RUN_DIR"
echo "Export Directory  : ${RUN_DIR}/bin/export/"
echo "=================================================================="

module load gcc
module load cuda

./bin/FluidX3D
