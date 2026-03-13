#.ONESHELL:
MAKEFLAGS += --no-print-directory

PIP           = pip3
VENV          = pipenv
MAKEFILE     := $(lastword $(abspath $(MAKEFILE_LIST)))
MAKEFILE_DIR := $(realpath $(dir $(MAKEFILE)))

SRC     = $(wildcard $(MAKEFILE_DIR)/*.py $(MAKEFILE_DIR)/stage/*.py)
OUTPUT := $(MAKEFILE_DIR)/output

.PHONY : active run check clean

ifeq (,$(findstring $(HOME)/.local/bin,$(PATH)))
PATH := $(HOME)/.local/bin:$(PATH)
endif

active: $(OUTPUT)/install
ifneq ($(MAKEFILE_DIR),$(CURDIR))
	@echo "WARNING: Virtual environments has restriction on project directory !"
else
	@-$(VENV) shell
endif

$(OUTPUT)/install: PIPENV_VENV_IN_PROJECT := 1
$(OUTPUT)/install: $(MAKEFILE_DIR)/Pipfile.lock $(SRC) | $(OUTPUT)
	@$(PIP) install pipenv --user
	@cd $(MAKEFILE_DIR) && $(VENV) install --ignore-pipfile && touch $@

run: $(OUTPUT)/install
	@cd $(MAKEFILE_DIR) && $(VENV) run ./installer.py $(opt)

requirements.txt: $(MAKEFILE_DIR)/Pipfile.lock
	@cd $(MAKEFILE_DIR) && $(VENV) requirements > $@

$(OUTPUT):
	@mkdir $@

clean:
	@cd $(MAKEFILE_DIR) && @$(VENV) --rm

release:
	@echo "使用生成的 requirements.txt 中的版本信息手动更新Pipfile"
	@echo '\t format: uvicorn = "==0.27.1"'

help:
	@echo "虚拟环境下的依赖必须使用 pipenv install pkg, 不要直接编辑 Pipfile !"
	@echo "pipenv install pandas	添加 pandas，并立即安装"
	@echo "pipenv lock	生成锁文件，不安装依赖"
	@echo "pipenv install	安装 Pipfile.lock 中所有依赖（必须）"
	@echo "每次添加新的项目依赖，必须生成新的 Pipfile.lock文件并提交，本文件不做 Pipfile /Piefile.lock 依赖关联，默认用户替代完成更新"

check: helm_check network_check install_check
helm_check:
	@echo "make comparsion with helm dry-run"

network_check:
	@echo "make comparsion with network probe"

install_check:
	@echo "make comparsion with status check"

performance_evaluation:
	@echo "bulabula ...."

