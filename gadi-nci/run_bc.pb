#!/bin/bash

#PBS -N bindcraft_5xwp
#PBS -P ye15
#PBS -q gpuhopper
#PBS -l ncpus=12
#PBS -l ngpus=1
#PBS -l mem=96GB
#PBS -l jobfs=100GB
#PBS -l walltime=24:00:00
#PBS -l storage=scratch/ye15+gdata/ye15
#PBS -l wd
#PBS -j oe

# Initialise environment and modules
#CONDA_BASE=$(conda info --base)
#source ${CONDA_BASE}/bin/activate ${CONDA_BASE}/envs/BindCraft
#export LD_LIBRARY_PATH=${CONDA_BASE}/lib
CONDA_BASE="/scratch/ye15/kg5799/miniforge"
BC_ENV="${CONDA_BASE}/conda_envs/BindCraft"

export CONDARC="${CONDA_BASE}/.condarc"
source "${CONDA_BASE}/etc/profile.d/conda.sh"
conda activate "${BC_ENV}"

# alternatively you can source the environment directly
#source /path/to/mambaforge/bin/activate /path/to/mambaforge/envs/BindCraft
#conda activate /scratch/ye15/kg5799/miniforge/conda_envs/BindCraft

# Get the directory where the bindcraft script is located
#SCRIPT_DIR=$(dirname "$0")
SCRIPT_DIR="/scratch/ye15/kg5799/protein-design/bindcraft/BindCraft"

# Parsing command line options
SETTINGS="/scratch/ye15/kg5799/protein-design/bindcraft/run_5XWP/5XWP.json"
FILTERS="/scratch/ye15/kg5799/protein-design/bindcraft/BindCraft/settings_filters/default_filters.json"
ADVANCED="/scratch/ye15/kg5799/protein-design/bindcraft/BindCraft/settings_advanced/default_4stage_multimer.json"
TEMP=$(getopt -o s:f:a: --long settings:,filters:,advanced: -n 'bindcraft.slurm' -- "$@")
eval set -- "$TEMP"

while true ; do
    case "$1" in
        -s|--settings) SETTINGS="$2" ; shift 2 ;;
        -f|--filters) FILTERS="$2" ; shift 2 ;;
        -a|--advanced) ADVANCED="$2" ; shift 2 ;;
        --) shift ; break ;;
        *) echo "Invalid Option" ; exit 1 ;;
    esac
done

# Ensure that SETTINGS is not empty
if [ -z "$SETTINGS" ]; then
    echo "Error: The -s or --settings option is required."
    exit 1
fi

echo "Running the BindCraft pipeline"
python -u "${SCRIPT_DIR}/bindcraft.py" --settings "${SETTINGS}" --filters "${FILTERS}" --advanced "${ADVANCED}"
