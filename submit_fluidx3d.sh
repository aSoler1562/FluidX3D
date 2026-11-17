#!/bin/bash --login
# ==============================================================================
# CSF3 Unified GPU / CPU Batch Submission Script for FluidX3D
#
# Stages the compiled binary (`bin/FluidX3D`), `stl/` folder, and a snapshot of
# `src/setup_barbs.cpp` + `src/defines.hpp` into:
#   ~/scratch/FLUIDX3D_MICRO_LBM/<CASE_NAME>/
# and passes the target resolution `DX_UM` (in micrometers) at runtime so you do
# not need to manually edit `dx_um` in `src/setup_barbs.cpp` between runs.
#
# Usage (from anywhere):
#   ./submit_fluidx3d.sh <MODE> <CASE_NAME> [DX_UM] [WALLTIME] [CPUS]
#
# Examples:
#   ./submit_fluidx3d.sh gpuA dx_0_5um 0.5          # A100 80GB, dx = 0.5 um
#   ./submit_fluidx3d.sh gpuA dx_0_5um              # Auto-detects dx = 0.5 um from 'dx_0_5um'
#   ./submit_fluidx3d.sh gpuL dx_1um 1.0            # L40S GPU, dx = 1.0 um
#   ./submit_fluidx3d.sh gpuV dx_0p5um 0.5 08:00:00 4
#   ./submit_fluidx3d.sh cpu mesh_test 2.0          # CPU on -p multicore, dx = 2.0 um
# ==============================================================================

set -e

MODE="${1:-gpu}"
CASE_NAME="${2:-default}"

# Determine whether arg 3 is DX_UM (a number like 2, 1, 0.5) or WALLTIME (contains ':' or '-')
ARG3="${3:-}"
if [[ -n "$ARG3" && "$ARG3" != *:* && "$ARG3" != *-* ]]; then
    DX_UM="$ARG3"
    WALLTIME_ARG="${4:-}"
    CPUS_ARG="${5:-}"
else
    DX_UM=""
    WALLTIME_ARG="${3:-}"
    CPUS_ARG="${4:-}"
fi

# If DX_UM was not explicitly provided, infer it from CASE_NAME (e.g. dx_0_5um -> 0.5, dx_0p5um -> 0.5, dx_1um -> 1)
if [[ -z "$DX_UM" ]]; then
    if [[ "$CASE_NAME" =~ ([0-9]+)[_p\.]([0-9]+)um ]]; then
        DX_UM="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$CASE_NAME" =~ ([0-9]+)um ]]; then
        DX_UM="${BASH_REMATCH[1]}"
    fi
fi

# Locate source repository (supports ~/FLUIDX3D_MICRO_LBM, ~/FLUID3D_MICRO_LBM, or script dir)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -d "${SCRIPT_DIR}/src" ]]; then
    SRC_DIR="$SCRIPT_DIR"
elif [[ -d "${HOME}/FLUIDX3D_MICRO_LBM/src" ]]; then
    SRC_DIR="${HOME}/FLUIDX3D_MICRO_LBM"
elif [[ -d "${HOME}/FLUID3D_MICRO_LBM/src" ]]; then
    SRC_DIR="${HOME}/FLUID3D_MICRO_LBM"
elif [[ -f "${SCRIPT_DIR}/bin/FluidX3D" ]]; then
    SRC_DIR="$SCRIPT_DIR"
else
    echo "Error: Could not find FluidX3D repository or bin/FluidX3D."
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
    gpuA2)
        PARTITION="gpuA"
        EXTRA_FLAGS=(--gres=gpu:2)
        DEFAULT_CPUS=8
        DEFAULT_TIME="04:00:00"
		DEFAULT_DZ=8
		DEVICE_ARGS=(0 0 0 0 1 1 1 1)
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

WALLTIME="${WALLTIME_ARG:-$DEFAULT_TIME}"
CPUS="${CPUS_ARG:-$DEFAULT_CPUS}"

# ==============================================================================
# Step 1: When run from terminal -> compile if needed, stage files & submit sbatch
# ==============================================================================
if [[ -z "$SLURM_JOB_ID" ]]; then
    # Auto-compile if binary is missing or older than setup_barbs.cpp / defines.hpp
    if [[ -d "${SRC_DIR}/src" ]]; then
        if [[ ! -f "${SRC_DIR}/bin/FluidX3D" || "${SRC_DIR}/src/setup_barbs.cpp" -nt "${SRC_DIR}/bin/FluidX3D" || "${SRC_DIR}/src/defines.hpp" -nt "${SRC_DIR}/bin/FluidX3D" ]]; then
            echo "Compiling updated source in ${SRC_DIR} ..."
            (
                cd "$SRC_DIR"
                module load gcc 2>/dev/null || true
                module load cuda 2>/dev/null || true
                make Linux -j4
            )
        fi
    fi

    mkdir -p "${RUN_DIR}/bin/export" "${RUN_DIR}/stl" "${RUN_DIR}/src_snapshot"

    if [[ "$SRC_DIR" != "$RUN_DIR" ]]; then
        echo "Staging case '$CASE_NAME' from $SRC_DIR -> $RUN_DIR ..."
        cp -f "${SRC_DIR}/bin/FluidX3D" "${RUN_DIR}/bin/FluidX3D"
        cp -rf "${SRC_DIR}/stl/"* "${RUN_DIR}/stl/"
        # Save a snapshot of setup_barbs.cpp and defines.hpp for version tracking
        cp -f "${SRC_DIR}/src/setup_barbs.cpp" "${SRC_DIR}/src/defines.hpp" "${RUN_DIR}/src_snapshot/" 2>/dev/null || true
    fi
    cp -f "$0" "${RUN_DIR}/submit_fluidx3d.sh"

    cat << 'EOF' > "${RUN_DIR}/watch_convergence.gp"
# Live Gnuplot convergence monitor for FluidX3D
# Usage (X11 window):   module load apps/gcc/gnuplot && gnuplot watch_convergence.gp
# Usage (SSH terminal): module load apps/gcc/gnuplot && gnuplot -e "DUMB=1" watch_convergence.gp
# Usage (PNG export):   module load apps/gcc/gnuplot && gnuplot -e "PNG=1" watch_convergence.gp

FILE = "bin/export/convergence.dat"

if (exists("PNG")) {
    set term pngcairo size 1400,900 enhanced font "Sans,10"
    set output "bin/export/convergence_live.png"
} else {
    if (exists("DUMB")) {
        set term dumb size 140,42
    } else {
        set term x11 noraise size 1200,800
    }
}

set multiplot layout 2,2 title "FluidX3D Live Engineering Convergence (" . system("pwd") . ")"
set grid

set xlabel "Step t"
set ylabel "U_sup [m/s]"
plot FILE u 1:4 w lp pt 7 lw 1.5 lc rgb "#1f77b4" title "U_sup [m/s]"

set ylabel "K_layer [um^2]"
plot FILE u 1:5 w lp pt 5 lw 1.5 lc rgb "#2ca02c" title "K_layer [um^2]"

set ylabel "dQ/Q (log scale)"
set logscale y
plot FILE u 1:6 w lp pt 9 lw 1.5 lc rgb "#ff7f0e" title "dQ/Q", \
     1e-4 w l dt 2 lw 2 lc rgb "#d62728" title "conv_tol = 1e-4"
unset logscale y

set ylabel "Plane Continuity Ratio"
set yrange [0.95:1.05]
plot FILE u 1:7 w lp pt 13 lw 1.5 lc rgb "#9467bd" title "Q_above / Q_below", \
     FILE u 1:8 w lp pt 6  lw 1.2 lc rgb "#8c564b" title "Q_mid / Q_below", \
     1.0 w l dt 2 lw 1.5 lc rgb "black" title "Ideal (1.0)"
unset yrange

unset multiplot

if (!exists("PNG")) {
    pause 5
    reread
}
EOF

    cd "$RUN_DIR"
    JOB_ID=$(sbatch --parsable \
        -J "fx3d_${CASE_NAME}" \
        -p "$PARTITION" \
        "${EXTRA_FLAGS[@]}" \
        -n "$CPUS" \
        -t "$WALLTIME" \
        -o "${RUN_DIR}/fluidx3d_%j.log" \
        "${RUN_DIR}/submit_fluidx3d.sh" "$MODE" "$CASE_NAME" "$DX_UM" "$WALLTIME" "$CPUS")

    echo "=================================================================="
    echo "Submitted FluidX3D Job ID : $JOB_ID"
    echo "Case Name                 : $CASE_NAME"
    echo "Target Resolution (dx_um) : ${DX_UM:-default in setup_barbs.cpp}"
    echo "Mode / Partition          : $MODE (-p $PARTITION ${EXTRA_FLAGS[*]})"
    echo "CPU Cores / Walltime      : $CPUS cores, $WALLTIME"
    echo "Case Run Directory        : $RUN_DIR"
    echo "Results & VTK Export Dir  : ${RUN_DIR}/bin/export/"
    echo "Config Snapshot Saved In  : ${RUN_DIR}/src_snapshot/"
    echo "Log File                  : ${RUN_DIR}/fluidx3d_${JOB_ID}.log"
    echo "Monitor log with          : tail -f ${RUN_DIR}/fluidx3d_${JOB_ID}.log"
    echo "Monitor plots (X11 GUI)   : cd ${RUN_DIR} && module load apps/gcc/gnuplot && gnuplot watch_convergence.gp"
    echo "Monitor plots (SSH ASCII) : cd ${RUN_DIR} && module load apps/gcc/gnuplot && gnuplot -e 'DUMB=1' watch_convergence.gp"
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
echo "Target dx [um]    : ${DX_UM:-default}"
echo "Compute Node      : $(hostname)"
echo "Partition         : $PARTITION"
echo "Working Directory : $RUN_DIR"
echo "Export Directory  : ${RUN_DIR}/bin/export/"
echo "=================================================================="

module load gcc
module load cuda

if [[ -n "${DEFAULT_DZ:-}" ]]; then
	export FLUIDX3D_DZ="${FLUIDX3D_DZ:-$DEFAULT_DZ}"
fi

if [[ -n "$DX_UM" ]]; then
	export FLUIDX3D_DX_UM="$DX_UM"
	./bin/FluidX3D "$DX_UM" "${DEVICE_ARGS[@]}"
else
	./bin/FluidX3D "${DEVICE_ARGS[@]}"
fi
