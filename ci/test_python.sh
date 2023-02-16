#!/bin/bash
# Copyright (c) 2022-2023, NVIDIA CORPORATION.

set -euo pipefail

. /opt/conda/etc/profile.d/conda.sh

rapids-logger "Generate Python testing dependencies"
rapids-dependency-file-generator \
  --output conda \
  --file_key test_python \
  --matrix "cuda=${RAPIDS_CUDA_VERSION%.*};arch=$(arch);py=${RAPIDS_PY_VERSION}" | tee env.yaml

rapids-mamba-retry env create --force -f env.yaml -n test

# Temporarily allow unbound variables for conda activation.
set +u
conda activate test
set -u

rapids-logger "Downloading artifacts from previous jobs"
CPP_CHANNEL=$(rapids-download-conda-from-s3 cpp)
PYTHON_CHANNEL=$(rapids-download-conda-from-s3 python)

RAPIDS_TESTS_DIR=${RAPIDS_TESTS_DIR:-"${PWD}/test-results"}
RAPIDS_COVERAGE_DIR=${RAPIDS_COVERAGE_DIR:-"${PWD}/coverage-results"}
mkdir -p "${RAPIDS_TESTS_DIR}" "${RAPIDS_COVERAGE_DIR}"

rapids-print-env

if [[ "${RAPIDS_CUDA_VERSION}" != "11.8.0" ]]; then
  rapids-mamba-retry install \
    --force-reinstall \
    --channel pytorch \
    --channel pytorch-nightly \
    'pytorch::pytorch>=1.13.1' \
    'pytorch-cuda>=11.7'
fi

rapids-mamba-retry install \
  --channel "${CPP_CHANNEL}" \
  --channel "${PYTHON_CHANNEL}" \
  --channel pyg \
  libcugraph \
  pylibcugraph \
  cugraph \
  cugraph-pyg \
  cugraph-service-server \
  cugraph-service-client

rapids-logger "Check GPU usage"
nvidia-smi

# RAPIDS_DATASET_ROOT_DIR is used by test scripts
export RAPIDS_DATASET_ROOT_DIR="$(realpath datasets)"
pushd "${RAPIDS_DATASET_ROOT_DIR}"
./get_test_data.sh
popd

EXITCODE=0
trap "EXITCODE=1" ERR
set +e

rapids-logger "pytest pylibcugraph"
pushd python/pylibcugraph/pylibcugraph
pytest \
  --cache-clear \
  --junitxml="${RAPIDS_TESTS_DIR}/junit-pylibcugraph.xml" \
  --cov-config=../../.coveragerc \
  --cov=pylibcugraph \
  --cov-report=xml:"${RAPIDS_COVERAGE_DIR}/pylibcugraph-coverage.xml" \
  --cov-report=term \
  tests
popd

rapids-logger "pytest cugraph"
pushd python/cugraph/cugraph
pytest \
  --ignore=tests/mg \
  --cache-clear \
  --junitxml="${RAPIDS_TESTS_DIR}/junit-cugraph.xml" \
  --cov-config=../../.coveragerc \
  --cov=cugraph \
  --cov-report=xml:"${RAPIDS_COVERAGE_DIR}/cugraph-coverage.xml" \
  --cov-report=term \
  tests
popd

rapids-logger "pytest cugraph benchmarks (run as tests)"
pushd benchmarks
pytest \
  --capture=no \
  --verbose \
  -m "managedmem_on and poolallocator_on and tiny" \
  --benchmark-disable \
  cugraph/pytest-based/bench_algos.py
popd

if [[ "${RAPIDS_CUDA_VERSION}" != "11.8.0" ]]; then
  rapids-logger "pytest cugraph_pyg (single GPU)"
  pushd python/cugraph-pyg/cugraph_pyg
  # rmat is not tested because of multi-GPU testing
  pytest \
    --cache-clear \
    --ignore=tests/int \
    --ignore=tests/mg \
    --junitxml="${RAPIDS_TESTS_DIR}/junit-cugraph-pyg.xml" \
    --cov-config=../../.coveragerc \
    --cov=cugraph_pyg \
    --cov-report=xml:"${RAPIDS_COVERAGE_DIR}/cugraph-pyg-coverage.xml" \
    --cov-report=term \
    .
  popd
else
  rapids-logger "skipping cugraph_pyg pytest on CUDA 11.8"
fi

rapids-logger "pytest cugraph-service (single GPU)"
pushd python/cugraph-service
pytest \
  --capture=no \
  --verbose \
  --cache-clear \
  --junitxml="${RAPIDS_TESTS_DIR}/junit-cugraph-service.xml" \
  --cov-config=../.coveragerc \
  --cov=cugraph_service_client \
  --cov=cugraph_service_server \
  --cov-report=xml:"${RAPIDS_COVERAGE_DIR}/cugraph-service-coverage.xml" \
  --cov-report=term \
  --benchmark-disable \
  -k "not mg" \
  tests
popd

rapids-logger "Test script exiting with value: $EXITCODE"
exit ${EXITCODE}
