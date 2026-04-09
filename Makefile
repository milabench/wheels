.EXPORT_ALL_VARIABLES:
include .env

CUDA_MAJOR  := $(word 1,$(subst ., ,$(CUDA_VERSION)))
CUDA_MINOR  := $(word 2,$(subst ., ,$(CUDA_VERSION)))
TORCH_MAJOR := $(word 1,$(subst ., ,$(PYTORCH_VERSION)))
TORCH_MINOR := $(word 2,$(subst ., ,$(PYTORCH_VERSION)))

CUDA_SHORT       := cu$(CUDA_MAJOR)$(CUDA_MINOR)
PT_VER           := pt$(TORCH_MAJOR)$(TORCH_MINOR)
TORCH_SHORT      := $(TORCH_MAJOR).$(TORCH_MINOR)
WHEEL_CUDA_VERSION := $(CUDA_MAJOR)
WHEELS_DIR       ?= $(CURDIR)/wheels

.PHONY: all xformers pyg pytorch-cluster pytorch-sparse pytorch-scatter \
        torchao flash-attention flash-attention-4 install-pytorch clean

all: xformers pyg torchao flash-attention flash-attention-4

pyg: pytorch-cluster pytorch-sparse pytorch-scatter

xformers:
	bash scripts/build-xformers.sh

pytorch-cluster:
	bash scripts/build-pyg.sh pytorch_cluster

pytorch-sparse:
	bash scripts/build-pyg.sh pytorch_sparse

pytorch-scatter:
	bash scripts/build-pyg.sh pytorch_scatter

torchao:
	bash scripts/build-torchao.sh

flash-attention:
	bash scripts/build-flash-attention.sh

flash-attention-4:
	bash scripts/build-flash-attention-4.sh

install-pytorch:
	pip install --no-cache-dir torch==$(PYTORCH_VERSION) \
		--index-url https://download.pytorch.org/whl/$(CUDA_SHORT)

clean:
	rm -rf wheels/
