#!/bin/bash
# =============================================================================
#  De novo protein binder design pipeline against target 5XWP
#  Platform: NCI Gadi (PBSPro scheduler), single GPU job
#
#  STAGE 1  RFD3        de novo binder BACKBONES around the target hotspots
#  STAGE 2  ProteinMPNN  SEQUENCES for each backbone (inverse folding)
#  STAGE 3  RF3          FOLD each sequence back (self-consistency check)
#
#  Output of each stage feeds the next:
#     RFD3 *.cif(.gz)  ->  MPNN  ->  *_b0_d*.cif  ->  RF3 fold
#
#  All tunable values live in the CONFIG block below -- nothing is hardcoded
#  inside the commands, so you can retarget / re-tune without editing logic.
# =============================================================================

#PBS -N rfd3_5xwp                          # job name
#PBS -P ye15                               # project to charge
#PBS -q gpuhopper                          # GPU queue (H100/H200)
#PBS -l ncpus=12                           # CPUs
#PBS -l ngpus=1                            # GPUs
#PBS -l mem=96GB                           # host RAM (not GPU VRAM)
#PBS -l jobfs=100GB                        # node-local scratch
#PBS -l walltime=24:00:00                  # max wall time
#PBS -l storage=scratch/ye15+gdata/ye15    # accessible filesystems
#PBS -l wd                                 # start in submission dir
#PBS -j oe                                 # merge stdout+stderr

set -euo pipefail
module load singularity

# #############################################################################
#  CONFIG  --  EDIT EVERYTHING HERE. The logic below should not need changes.
# #############################################################################

# ---- Locations --------------------------------------------------------------
BASE=/scratch/ye15/$USER/protein-design/rf3   # project root
SIF=${BASE}/foundry.sif                        # container image
WEIGHTS_BIND=""                                # host weights dir to bind, e.g.
                                               #   /scratch/ye15/$USER/weights
                                               # leave "" if /weights is in the image

TARGET_DIR=${BASE}/target
INPUT_DIR=${BASE}/inputs
RFD3_OUT=${BASE}/rfd3_outputs
MPNN_DIR=${BASE}/mpnn_output
RF3_OUT=${BASE}/rf3_outputs

# Where RFD3 writes its result .cif/.cif.gz files, relative to RFD3_OUT.
# "." means directly in RFD3_OUT; change to e.g. "final_models" if RFD3 nests them.
RFD3_RESULT_SUBDIR="."

# ---- Target / design definition (drives the RFD3 input JSON) ----------------
DESIGN_NAME="5xwp_binder_100aa"                # key in the JSON / output naming
TARGET_PDB="${TARGET_DIR}/5XWP_clean.pdb"      # cleaned target structure
DIALECT=2
CONTIG="100-100,/0,A0-97,A103-311,A316-629,A643-667,A675-1153"
COMPLEX_LENGTH="1225-1225"
INFER_ORI_STRATEGY="hotspots"
IS_NON_LOOPY=true

# Hotspots as an associative array: residue -> atoms. Edit/add/remove freely;
# the JSON is generated from this, so you never touch the JSON by hand.
declare -A HOTSPOTS=(
  [A411]="CG1,CG2"
  [A421]="CG1,CG2"
  [A473]="ND1,NE2"
  [A995]="CD1,CD2,CE1,CE2,CZ"
)

# ---- Model weights (paths AS SEEN INSIDE the container) ---------------------
MPNN_CKPT=/weights/proteinmpnn_v_48_020.pt
RF3_CKPT=/weights/rf3_foundry_01_24_latest_remapped.ckpt

# ---- Stage 1: RFD3 parameters ----------------------------------------------
RFD3_N_BATCHES=1
RFD3_DIFFUSION_BATCH_SIZE=8        # lower (4/2/1) if this stage OOMs
RFD3_SKIP_EXISTING=False
RFD3_DUMP_TRAJECTORIES=True        # False to save disk
RFD3_PREVALIDATE_INPUTS=False
RFD3_STEP_SCALE=3

# ---- Stage 2: ProteinMPNN parameters ---------------------------------------
MPNN_MODEL_TYPE="protein_mpnn"
MPNN_BATCH_SIZE=8
MPNN_NUMBER_OF_BATCHES=1
MPNN_IS_LEGACY_WEIGHTS="True"
MPNN_RESULT_GLOB="*_b0_d*.cif"     # pattern of MPNN outputs to fold

# ---- Stage 3: RF3 parameters ------------------------------------------------
RF3_DISABLE_CUEQUIVARIANCE="True"

# ---- CUDA allocator ---------------------------------------------------------
CUDA_ALLOC_CONF="expandable_segments:True"

# #############################################################################
#  LOGIC  --  generally no need to edit below here.
# #############################################################################

export PYTORCH_CUDA_ALLOC_CONF="${CUDA_ALLOC_CONF}"
INPUT_JSON="${INPUT_DIR}/${DESIGN_NAME}.json"
RFD3_RESULT_DIR="${RFD3_OUT}/${RFD3_RESULT_SUBDIR}"

# Assemble optional --bind argument for weights (empty if WEIGHTS_BIND unset).
BIND_ARGS=()
if [ -n "${WEIGHTS_BIND}" ]; then
  BIND_ARGS=(--bind "${WEIGHTS_BIND}:/weights")
fi

mkdir -p "${TARGET_DIR}" "${INPUT_DIR}" "${RFD3_OUT}" "${MPNN_DIR}" "${RF3_OUT}"

# ---- Pre-flight -------------------------------------------------------------
echo "==> Pre-flight checks"
[ -f "${SIF}" ]        || { echo "ERROR: container not found: ${SIF}" >&2; exit 1; }
[ -f "${TARGET_PDB}" ] || { echo "ERROR: target not found: ${TARGET_PDB}" >&2
                            echo "       Stage it on a login node first." >&2; exit 1; }
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader | sed 's/^/    GPU: /'

# ---- Build the RFD3 input JSON from the CONFIG variables --------------------
# Build the hotspots object programmatically so it always matches the array.
build_hotspots_json() {
  local first=1 k
  printf '{'
  for k in "${!HOTSPOTS[@]}"; do
    [ $first -eq 0 ] && printf ','
    printf '\n      "%s": "%s"' "$k" "${HOTSPOTS[$k]}"
    first=0
  done
  printf '\n    }'
}

echo "==> Writing RFD3 input: ${INPUT_JSON}"
cat > "${INPUT_JSON}" <<JSON
{
  "${DESIGN_NAME}": {
    "dialect": ${DIALECT},
    "input": "${TARGET_PDB}",
    "contig": "${CONTIG}",
    "length": "${COMPLEX_LENGTH}",
    "select_hotspots": $(build_hotspots_json),
    "infer_ori_strategy": "${INFER_ORI_STRATEGY}",
    "is_non_loopy": ${IS_NON_LOOPY}
  }
}
JSON

# Validate the JSON we just generated (fail early on a bad edit).
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open('${INPUT_JSON}'))" \
    || { echo "ERROR: generated JSON is invalid: ${INPUT_JSON}" >&2; exit 1; }
fi

# =============================================================================
#  STAGE 1 -- RFD3 backbone design
# =============================================================================
echo "==> [1/3] RFD3 backbone design"
singularity exec --nv "${BIND_ARGS[@]}" \
  --env PYTORCH_CUDA_ALLOC_CONF="${CUDA_ALLOC_CONF}" \
  "${SIF}" rfd3 design \
    out_dir="${RFD3_OUT}" \
    inputs="${INPUT_JSON}" \
    n_batches="${RFD3_N_BATCHES}" \
    diffusion_batch_size="${RFD3_DIFFUSION_BATCH_SIZE}" \
    skip_existing="${RFD3_SKIP_EXISTING}" \
    dump_trajectories="${RFD3_DUMP_TRAJECTORIES}" \
    prevalidate_inputs="${RFD3_PREVALIDATE_INPUTS}" \
    inference_sampler.step_scale="${RFD3_STEP_SCALE}"

# ---- Decompress any gzipped outputs -----------------------------------------
# RFD3 may write .cif.gz; MPNN needs plain .cif. Unzip in place (keep nothing
# zipped behind). -f overwrites, -k not used so the .gz is replaced.
echo "==> Decompressing RFD3 outputs in ${RFD3_RESULT_DIR}"
shopt -s nullglob
gz_files=("${RFD3_RESULT_DIR}"/*.cif.gz)
shopt -u nullglob
if [ ${#gz_files[@]} -gt 0 ]; then
  echo "    gunzipping ${#gz_files[@]} file(s)"
  gunzip -f "${gz_files[@]}"
fi

# ---- Gate: did RFD3 produce any .cif structures? ----------------------------
shopt -s nullglob
rfd3_cifs=("${RFD3_RESULT_DIR}"/*.cif)
shopt -u nullglob
if [ ${#rfd3_cifs[@]} -eq 0 ]; then
  echo "ERROR: RFD3 produced no .cif files in ${RFD3_RESULT_DIR} -- stopping." >&2
  echo "       (Check RFD3_RESULT_SUBDIR if RFD3 nests its output.)" >&2
  exit 1
fi
echo "    RFD3 produced ${#rfd3_cifs[@]} structures."

# =============================================================================
#  STAGE 2 -- ProteinMPNN sequence design
# =============================================================================
echo "==> [2/3] ProteinMPNN sequence design"
for cif in "${rfd3_cifs[@]}"; do
  echo "    MPNN on $(basename "${cif}")"
  singularity run --nv "${BIND_ARGS[@]}" "${SIF}" mpnn \
    --model_type "${MPNN_MODEL_TYPE}" \
    --structure_path "${cif}" \
    --out_directory "${MPNN_DIR}" \
    --batch_size "${MPNN_BATCH_SIZE}" \
    --number_of_batches "${MPNN_NUMBER_OF_BATCHES}" \
    --is_legacy_weights "${MPNN_IS_LEGACY_WEIGHTS}" \
    --checkpoint_path "${MPNN_CKPT}"
done

# ---- Gate: did MPNN produce sequence models? --------------------------------
shopt -s nullglob
mpnn_cifs=("${MPNN_DIR}"/${MPNN_RESULT_GLOB})
shopt -u nullglob
if [ ${#mpnn_cifs[@]} -eq 0 ]; then
  echo "ERROR: MPNN produced no ${MPNN_RESULT_GLOB} files in ${MPNN_DIR} -- stopping." >&2
  exit 1
fi
echo "    MPNN produced ${#mpnn_cifs[@]} sequence models."

# =============================================================================
#  STAGE 3 -- RF3 folding / self-consistency validation
# =============================================================================
echo "==> [3/3] RF3 folding"
for cif in "${mpnn_cifs[@]}"; do
  name=$(basename "${cif}" .cif)
  echo "    Folding ${name}"
  singularity exec --nv "${BIND_ARGS[@]}" \
    --env DISABLE_CUEQUIVARIANCE="${RF3_DISABLE_CUEQUIVARIANCE}" \
    "${SIF}" rf3 fold \
      inputs="${cif}" \
      ckpt_path="${RF3_CKPT}" \
      out_dir="${RF3_OUT}/${name}"
done

# =============================================================================
#  SUMMARY
# =============================================================================
echo "==> Pipeline complete."
find "${RF3_OUT}" -type f \( -name "*.pdb" -o -name "*.cif" \) > "${BASE}/rf3_structures.txt"
echo "    Final folded structures listed in: ${BASE}/rf3_structures.txt"
wc -l < "${BASE}/rf3_structures.txt" | sed 's/^/    count: /'
