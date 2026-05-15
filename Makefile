.EXPORT_ALL_VARIABLES:
include .env

GPU_BACKEND ?= cuda
PYTHON      ?= python3.12

CUDA_MAJOR  := $(word 1,$(subst ., ,$(CUDA_VERSION)))
CUDA_MINOR  := $(word 2,$(subst ., ,$(CUDA_VERSION)))
ROCM_MAJOR  := $(word 1,$(subst ., ,$(ROCM_VERSION)))
ROCM_MINOR  := $(word 2,$(subst ., ,$(ROCM_VERSION)))
TORCH_MAJOR := $(word 1,$(subst ., ,$(PYTORCH_VERSION)))
TORCH_MINOR := $(word 2,$(subst ., ,$(PYTORCH_VERSION)))

CUDA_SHORT       := cu$(CUDA_MAJOR)$(CUDA_MINOR)
ROCM_SHORT       := rocm$(ROCM_MAJOR).$(ROCM_MINOR)
PT_VER           := pt$(TORCH_MAJOR)$(TORCH_MINOR)
TORCH_SHORT      := $(TORCH_MAJOR).$(TORCH_MINOR)
WHEEL_CUDA_VERSION := $(CUDA_MAJOR)
WHEELS_DIR       ?= $(CURDIR)/wheels

ifeq ($(GPU_BACKEND),rocm)
  ACCEL_SHORT := $(ROCM_SHORT)
else
  ACCEL_SHORT := $(CUDA_SHORT)
endif

VENV_DIR     := .venv-$(ACCEL_SHORT)
VENV_SENTINEL := $(VENV_DIR)/.torch-$(PYTORCH_VERSION)

# Activate the venv for every recipe
export VIRTUAL_ENV := $(CURDIR)/$(VENV_DIR)
export PATH := $(CURDIR)/$(VENV_DIR)/bin:$(PATH)

.PHONY: all xformers pyg pytorch-cluster pytorch-sparse pytorch-scatter \
        torchao flash-attention flash-attention-4 \
        aiter amdsmi vllm clean

all: xformers pyg torchao flash-attention flash-attention-4

pyg: pytorch-cluster pytorch-sparse pytorch-scatter

# ---------- environment setup (automatic) ----------

$(VENV_DIR):
	uv venv $(VENV_DIR) --python $(PYTHON) --seed

$(VENV_SENTINEL): | $(VENV_DIR)
	uv pip install --python $(VENV_DIR)/bin/python \
		torch==$(PYTORCH_VERSION) \
		--index-url https://download.pytorch.org/whl/$(ACCEL_SHORT)
	@touch $@

# ---------- build targets ----------

xformers: $(VENV_SENTINEL)
	bash scripts/build-xformers.sh

pytorch-cluster: $(VENV_SENTINEL)
	bash scripts/build-pyg.sh pytorch_cluster

pytorch-sparse: $(VENV_SENTINEL)
	bash scripts/build-pyg.sh pytorch_sparse

pytorch-scatter: $(VENV_SENTINEL)
	bash scripts/build-pyg.sh pytorch_scatter

torchao: $(VENV_SENTINEL)
	bash scripts/build-torchao.sh

flash-attention: $(VENV_SENTINEL)
	bash scripts/build-flash-attention.sh

flash-attention-4: $(VENV_SENTINEL)
	bash scripts/build-flash-attention-4.sh

aiter: $(VENV_SENTINEL)
	bash scripts/build-aiter.sh

amdsmi: $(VENV_SENTINEL)
	bash scripts/build-amdsmi.sh

vllm: flash-attention aiter amdsmi
	bash scripts/build-vllm.sh

clean:
	rm -rf wheels/ .venv-*/
