#!/bin/bash

## Parse command-line arguments

print_var() {
    echo "$1: ${!1}"
}

usage() {
    echo "Test T5X throughput on a fake-data Wikipedia benchmark or real SQuAD."
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "  OPTIONS                   DESCRIPTION"
    echo "  -a, --additional-args     Additional gin args to pass to t5x/train.py"
    echo "  -b, --batch-size          Global batch size (REQUIRED)"
    echo "  -c, --use-contrib-configs If provided uses contrib/gpu configs instead of top-level configs. Notably, gpu configs use adamw instead of adafactor"
    echo "  -d, --dtype               Data type, defaults to bfloat16."
    echo "  --enable-te {0,1}         1 to enable, 0 to disable; defaults to ENABLE_TE in env or 0 if unset"
    echo "  -e, --epochs              Number of epochs to run, defaults to 7."
    echo "  -f, --finetune            Uses squad1 finetuning configs (w/ dropout). By default will only use pre-training configs (no dropout)."
    echo "  --multiprocess            Enable the multiprocess GPU mode."
    echo "  -o, --output NAME         Name for the output folder, a temporary folder will be created if none specified."
    echo "  --seed INT                Random seed for deterministim. Defaults to 42."
    echo "  -s, --steps-per-epoch INT Steps per epoch. Detauls to 100"
    echo "  -h, --help                Print usage."
    exit $1
}

args=$(getopt -o a:b:cd:e:fho:s: --long additional-args:,batch-size:,use-contrib-configs,dtype:,enable-te:,epochs:,finetune,help,multiprocess,output:,seed:,steps-per-epoch: -- "$@")
if [[ $? -ne 0 ]]; then
    exit 1
fi

# Default arguments

ADDITIONAL_ARGS=""
BATCH_SIZE=0
USE_CONTRIB_CONFIGS=0
DTYPE=bfloat16
EPOCHS=7
FINETUNE=0
MULTIPROCESS=0
OUTPUT=$(mktemp -d)
SEED=42
STEPS_PER_EPOCH=100
ENABLE_TE=${ENABLE_TE:-0}

eval set -- "$args"
while [ : ]; do
    case "$1" in
        -a | --additional-args)
            ADDITIONAL_ARGS="$2"
            shift 2
            ;;
        -b | --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        -c | --use-contrib-configs)
            USE_CONTRIB_CONFIGS=1
            shift 1
            ;;
        -d | --dtype)
            DTYPE="$2"
            shift 2
            ;;
        --enable-te)
            ENABLE_TE="$2"
            shift 2
            ;;
        -e | --epochs)
            EPOCHS="$2"
            shift 2
            ;;
        -f | --finetune)
            FINETUNE=1
            shift 1
            ;;
        -h | --help)
            usage 1
            ;;
        --multiprocess)
            MULTIPROCESS=1
            shift 1
            ;;
        -o | --output)
            OUTPUT="$2"
            shift 2
            ;;
        --seed)
            SEED="$2"
            shift 2
            ;;
        -s | --steps-per-epoch)
            STEPS_PER_EPOCH="$2"
            shift 2
            ;;
        --)
            shift;
            break 
            ;;
        *)
            echo "UNKNOWN OPTION $1"
            usage 1
    esac
done

if [[ $BATCH_SIZE == 0 ]]; then
    echo "ERROR: Batch size must be specified."
    usage 1
fi

## Set derived variables

TRAIN_STEPS=$(($EPOCHS * $STEPS_PER_EPOCH))

print_var ADDITIONAL_ARGS
print_var BATCH_SIZE
print_var USE_CONTRIB_CONFIGS
print_var DTYPE
print_var ENABLE_TE
print_var EPOCHS
print_var FINETUNE
print_var OUTPUT
print_var MULTIPROCESS
print_var STEPS_PER_EPOCH
print_var TRAIN_STEPS

## Enter T5X source folder
T5X_DIR=$(dirname `python -c 'import t5x; print(*t5x.__path__)'`)
pushd ${T5X_DIR}

## Create Python module to define seqio data source
cat > dummy_wikipedia.py <<EOF
import functools
import seqio
import t5.data

seqio.TaskRegistry.add(
    "dummy_wikipedia",
    source=seqio.TfdsDataSource(tfds_name="wikipedia/20190301.als:1.0.0"),
    preprocessors=[
        functools.partial(
            t5.data.preprocessors.rekey, key_map={
                "inputs": None,
                "targets": "text"
            }
        ),
        seqio.preprocessors.tokenize,
        seqio.CacheDatasetPlaceholder(),
        t5.data.preprocessors.unsupervised,
        seqio.preprocessors.append_eos_after_trim,
    ],
    output_features=dict(
        inputs=seqio.Feature(
            vocabulary=t5.data.get_default_vocabulary(), add_eos=True, required=False
        ),
        targets=seqio.Feature(
            vocabulary=t5.data.get_default_vocabulary(), add_eos=True
        )
    ),
    metric_fns=[]
)
EOF

## Create GIN file
cat > pretrain.gin <<EOF
from __gin__ import dynamic_registration
from t5x import partitioning

# Register Dummy Wikipedia Seqio Task for benchmarking
import dummy_wikipedia
$(
if [[ $USE_CONTRIB_CONFIGS -eq 1 ]]; then
    echo "from t5x.contrib.gpu.t5 import network"
    echo "include 't5x/contrib/gpu/t5/t5_1_1/small.gin'"
    echo "include 't5x/contrib/gpu/t5/configs/runs/pretrain.gin'"
    echo "include 't5x/contrib/gpu/t5/t5_1_1/adamw_opt.gin'"
else
    echo "from t5x.examples.t5 import network"
    echo "include 't5x/examples/t5/t5_1_1/small.gin'"
    echo "include 't5x/configs/runs/pretrain.gin'"
fi
)
MIXTURE_OR_TASK_NAME = "dummy_wikipedia"
TASK_FEATURE_LENGTHS = {"inputs": 512, "targets": 114}

DROPOUT_RATE = 0.0
USE_CACHED_TASKS = False
TRAIN_STEPS = %gin.REQUIRED
BATCH_SIZE = %gin.REQUIRED

partitioning.PjitPartitioner:
    num_partitions = 1
EOF

cat > finetune.gin <<EOF
from __gin__ import dynamic_registration
# Need t5.data.mixtures for squad
from t5.data import mixtures
from t5x import partitioning
from t5x import utils

# Based on t5x/contrib/gpu/t5/t5_1_1/examples/large_squad1_finetune_adam.gin
import t5x.contrib.gpu.scripts_gpu.seqio_tasks
$(
if [[ $USE_CONTRIB_CONFIGS -eq 1 ]]; then
    echo "from t5x.contrib.gpu.t5 import network"
    echo "include 't5x/contrib/gpu/t5/t5_1_1/small.gin'"
    echo "include 't5x/contrib/gpu/t5/t5_1_1/adamw_opt.gin'"
else
    echo "from t5x.examples.t5 import network"
    echo "include 't5x/examples/t5/t5_1_1/small.gin'"
fi
)
# Using contrib config since it helps avoid repeating several gin overrides (e.g., DatasetConfig.split)
include 't5x/contrib/gpu/t5/configs/runs/finetune_squad1.gin'

MIXTURE_OR_TASK_NAME = "squad_v010_allanswers"
# Default is {"inputs": 956, "targets": 256}
TASK_FEATURE_LENGTHS = {"inputs": 512, "targets": 256}
INITIAL_CHECKPOINT_PATH = "gs://t5-data/pretrained_models/t5x/t5_1_1_large/checkpoint_1000000"
# Setting all splits to "validation" to overfit
train/utils.DatasetConfig.split = 'validation'
train_eval/utils.DatasetConfig.split = 'validation'
infer_eval/utils.DatasetConfig.split = 'validation'

DROPOUT_RATE = 0.1
USE_CACHED_TASKS = False
TRAIN_STEPS = %gin.REQUIRED
BATCH_SIZE = %gin.REQUIRED

# Default is a linear_warmup (base_learning_rate=0.001)
utils.create_learning_rate_scheduler.base_learning_rate = 0.01
utils.create_learning_rate_scheduler.factors = 'constant'

partitioning.PjitPartitioner:
    num_partitions = 1
EOF

## Launch
set -exou pipefail

export ENABLE_TE=$ENABLE_TE
if [[ $FINETUNE -eq 1 ]]; then
  # Train for a single step
  python -m t5x.train \
    --gin_file pretrain.gin \
    --gin.MODEL_DIR=\"${OUTPUT}\" \
    --gin.network.T5Config.dtype=\"${DTYPE}\" \
    --gin.TRAIN_STEPS=0 \
    --gin.BATCH_SIZE=${BATCH_SIZE} \
    --gin.train.eval_steps=0 \
    --gin.train.eval_period=${STEPS_PER_EPOCH} \
    --gin.train/utils.DatasetConfig.seed=${SEED} \
    --gin.train_eval/utils.DatasetConfig.seed=${SEED} \
    --gin.train.random_seed=${SEED} \
    $ADDITIONAL_ARGS \
    $([[ $MULTIPROCESS != 0 ]] && echo --multiprocess_gpu)
  python -m t5x.train \
    --gin_file finetune.gin \
    --gin.MODEL_DIR=\"${OUTPUT}\" \
    --gin.network.T5Config.dtype=\"${DTYPE}\" \
    --gin.TRAIN_STEPS=${TRAIN_STEPS} \
    --gin.BATCH_SIZE=${BATCH_SIZE} \
    --gin.train.eval_period=${STEPS_PER_EPOCH} \
    --gin.CheckpointConfig.save=None \
    --gin.train/utils.DatasetConfig.seed=${SEED} \
    --gin.train_eval/utils.DatasetConfig.seed=${SEED} \
    --gin.train.random_seed=${SEED} \
    $ADDITIONAL_ARGS \
    $([[ $MULTIPROCESS != 0 ]] && echo --multiprocess_gpu)
else
  python -m t5x.train \
    --gin_file pretrain.gin \
    --gin.MODEL_DIR=\"${OUTPUT}\" \
    --gin.network.T5Config.dtype=\"${DTYPE}\" \
    --gin.TRAIN_STEPS=${TRAIN_STEPS} \
    --gin.BATCH_SIZE=${BATCH_SIZE} \
    --gin.train.eval_steps=0 \
    --gin.train.eval_period=${STEPS_PER_EPOCH} \
    --gin.CheckpointConfig.save=None \
    --gin.train/utils.DatasetConfig.seed=${SEED} \
    --gin.train_eval/utils.DatasetConfig.seed=${SEED} \
    --gin.train.random_seed=${SEED} \
    $ADDITIONAL_ARGS \
    $([[ $MULTIPROCESS != 0 ]] && echo --multiprocess_gpu)
fi
echo "Output at ${OUTPUT}"
