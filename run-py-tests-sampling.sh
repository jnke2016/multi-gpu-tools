#!/bin/bash
# Copyright (c) 2021, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

RAPIDS_MG_TOOLS_DIR=${RAPIDS_MG_TOOLS_DIR:-$(cd $(dirname $0); pwd)}
source ${RAPIDS_MG_TOOLS_DIR}/script-env.sh

# FIXME: this is project-specific and should happen at the project level.
# module load cuda/11.0.3
activateCondaEnv

# FIXME: enforce 1st arg is present
NUM_GPUS=$1
NUM_NODES=$(python -c "from math import ceil;print(int(ceil($NUM_GPUS/float($GPUS_PER_NODE))))")
# Creates a string "0,1,2,3" if NUM_GPUS=4, for example, which can be
# used for setting CUDA_VISIBLE_DEVICES on single-node runs.
ALL_GPU_IDS=$(python -c "print(\",\".join([str(n) for n in range($NUM_GPUS)]))")

# NOTE: it's assumed TESTING_DIR has been created elsewhere! For
# example, cronjob.sh calls this script multiple times in parallel, so
# it will create, populate, etc. TESTING_DIR once ahead of time.

export CUPY_CACHE_DIR=${TESTING_DIR}

# Function for running a command that gets killed after a specific timeout and
# logs a timeout message. This also sets ERRORCODE appropriately.
LAST_EXITCODE=0
function handleTimeout {
    seconds=$1
    eval "timeout --signal=2 --kill-after=60 $*"
    LAST_EXITCODE=$?
    if (( $LAST_EXITCODE == 124 )); then
        logger "ERROR: command timed out after ${seconds} seconds"
    elif (( $LAST_EXITCODE == 137 )); then
        logger "ERROR: command timed out after ${seconds} seconds, and had to be killed with signal 9"
    fi
    ERRORCODE=$((ERRORCODE | ${LAST_EXITCODE}))
}

# set +e so the script continues to execute commands even if they return
# non-0. This is needed so all test commands run, but also means the exit code
# for this script must be managed separately in order to indicate that ALL test
# commands passed vs. just the last one.
set +e
set -o pipefail
ERRORCODE=0
RUN_DASK_CLUSTER_PID=""
########################################

cd $TESTING_DIR



export RAPIDS_DATASET_ROOT_DIR=$DATASETS_DIR


# FIXME: change or make the test glob a variable or parameter since
# this is cugraph-specific.


# Only a node with a SLURM_NODEID 1 or a SNMG can proceed with the rest of the nightly scrip
# This avoid code duplication and a lot of if statement
#if [[ $SLURM_NODEID == 1 || $NUM_NODES == 1 ]]; then
# Create a results dir unique for this run
#setupResultsDir

# sleep 5
# Create a log dir per test file per configuration. This will
# contain all dask scheduler/worker logs, the stdout/stderr of the
# test run itself, and any reports (XML, etc.) from the test run
# for the test file.  Export this var so called scripts will pick
# it up.
# RELATIVE_LOGS_DIR="$(basename --suffix=.py $test_file)/${NUM_GPUS}-GPUs"
export LOGS_DIR="${TESTING_RESULTS_DIR}"
mkdir -p $LOGS_DIR

setTee ${LOGS_DIR}/pytest_output_log.txt

echo -e "\n>>>>>>>> ${NUM_GPUS}-GPUs <<<<<<<<<"

DASK_STARTUP_ERRORCODE=0
if [[ $NUM_NODES -gt 1 ]]; then
        
    if [[ $SLURM_NODEID != 1 ]]; then
        # wait for the node starting the scheduler
        sleep 5
    fi

    # Export this for all node. If this is only exported for the with
    # SLURM_NODEID == 1, it causes a renumbering failure
    export UCX_MAX_RNDV_RAILS=1

    # setup the cluster: Each node regardless of if it will be use as a scheduler
    # too is running this script
    bash ${RAPIDS_MG_TOOLS_DIR}/run-cluster-dask-jobs.sh &

    # Only Node 1 is starting the scheduler 
    if [[ $SLURM_NODEID == 1 ]]; then
        # python tests will look for env var SCHEDULER_FILE when
        # determining what type of Dask cluster to create, so export
        # it here for subprocesses to see.
        export SCHEDULER_FILE=$SCHEDULER_FILE

        # Remove the handleTimeout and DASK_STARTUP_ERRORCODE
        # if want to debug for the scheduler file not being found
        # Starting the benchmark
        echo "STARTED" > ${STATUS_FILE}
        handleTimeout 300 python ${RAPIDS_MG_TOOLS_DIR}/wait_for_workers.py \
            --num-expected-workers ${NUM_GPUS} \
            --scheduler-file-path ${SCHEDULER_FILE} \

        DASK_STARTUP_ERRORCODE=$LAST_EXITCODE
    fi
    
else
    export CUDA_VISIBLE_DEVICES=$ALL_GPU_IDS
    logger "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
fi

if [[ $SLURM_NODEID == 1 || $NUM_NODES == 1 ]]; then 

    if [[ $DASK_STARTUP_ERRORCODE == 0 ]]; then
        logger "RUNNING: pytest -v -s --cache-clear --no-cov -k bench_cugraph_uniform_neighbor_sample"
        # FIXME: no timeout added
        pytest -v -s --benchmark-gpu-disable --benchmark-min-rounds=1 --cache-clear --no-cov -k "bench_cugraph_uniform_neighbor_sample"
        #pytest -v $test_file
        PYTEST_ERRORCODE=$LAST_EXITCODE
    else
        logger "Dask processes failed to start, not running tests for $test_file."
    fi

    if [[ $DASK_STARTUP_ERRORCODE == 0 ]]; then
        logger "pytest exited with code: $PYTEST_ERRORCODE, run-py-tests.sh overall exit code is: $ERRORCODE"
    fi

    unsetTee

    # Generate a crude report containing the status of each test file.
    test_status_string=PASSED
    if [[ $PYTEST_ERRORCODE != 0 ]]; then
        test_status_string=FAILED
    fi
    echo "$test_status_string ./${RELATIVE_LOGS_DIR}" >> ${TESTING_RESULTS_DIR}/pytest-results-${NUM_GPUS}-GPUs.txt

    # Only MNMG uses a status file to communicate
    if [[ $NUM_NODES -gt 1 ]]; then
        echo "FINISHED" > ${STATUS_FILE}

        # Wait for the other nodes to read the status file
        sleep 2
        rm -rf ${STATUS_FILE}
    fi

else
    if [[ $NUM_NODES -gt 1 ]]; then
        # Wait for the node holding both the scheduler and the workers to create the status file
        while [ ! -f "${STATUS_FILE}" ]
        do
            # FIXME: use Inotify wait to exit the loop once event occurs without having to sleep
            sleep 1
        done
        # This is targetting the workers node which are not used as schedulers
        # Wait for a signal from the status file only if there are more than 1 node
        until grep -q "FINISHED" "${STATUS_FILE}"
        do
            # FIXME: use Inotify wait to exit the loop once event occurs without having to sleep
            sleep 1
        done
        # Pause the supporting nodes to avoid a race conditions with the main node(SLURM_NODEID == 1)
        sleep 2
    fi
fi

# At this stage there should be no running processes except /usr/lpp/mmfs/bin/mmsysmon.py
dask_processes=$(pgrep -la dask)
python_processes=$(pgrep -la python)
echo "$dask_processes"
echo "$python_processes"

if [[ ${#python_processes[@]} -gt 1 || $dask_processes ]]; then
    logger "The client was not shutdown properly, killing dask/python processes for Node $SLURM_NODEID"
    # This can be caused by a job timeout
    pkill python
    pkill dask
    pgrep -la python
    pgrep -la dask
fi
sleep 2


logger "Exiting \"run-py-tests.sh $NUM_GPUS\" with $ERRORCODE"
exit $ERRORCODE
