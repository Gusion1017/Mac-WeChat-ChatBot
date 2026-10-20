# WeChat AI ChatBot — 常用开发命令入口
#
# 所有目标都是 scripts/ 下脚本的薄封装；参数与细节见各脚本头部和 docs/development.md。
# 用法：make            # 列出全部目标
#       make test       # Swift 单元测试

SHELL := /bin/bash
.DEFAULT_GOAL := help
SWIFT_FLAGS := $(if $(filter 1,$(SWIFT_DISABLE_SANDBOX)),--disable-sandbox,)
.PHONY: help setup bridge app install run dev test test-go check docs-check clean clean-all

help: ## 列出可用目标
	@awk 'BEGIN {FS = ":.*##"; printf "\nWeChat AI ChatBot\n\n"} \
		/^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' \
		$(MAKEFILE_LIST)
	@printf "\n文档：docs/development.md · docs/README.md\n\n"

setup: ## 下载并校验 Frida Gadget（hook/gadget/）
	bash scripts/fetch_gadget.sh

bridge: ## 构建 OneBot bridge（bridge/onebot，含 Go 测试）
	bash scripts/build_bridge.sh

app: ## 构建并打包 App（dist/WeChat AI.app）
	bash scripts/build_app.sh

install: ## 把 dist 中的 App 安装到 ~/Applications
	bash scripts/install_app.sh

run: ## 打开已安装的 App
	open "$$HOME/Applications/WeChat AI.app"

dev: ## 启动本地 Mock（AI 8787 + OneBot 58080），无需真机
	@printf '分别在两个终端运行：\n  python3 devtools/mock_ai.py --port 8787\n  python3 devtools/mock_onebot.py --port 58080 --token wechatai-local-token --demo\n'

test: ## Swift 单元测试（app/；SWIFT_DISABLE_SANDBOX=1 适配受限沙箱）
	cd app && swift test $(SWIFT_FLAGS)

test-go: ## 构建 bridge 并跑 Go 测试（工具链由 build_bridge.sh 准备）
	bash scripts/build_bridge.sh

check: ## 静态检查 + Swift 测试（scripts/check.sh）
	bash scripts/check.sh

docs-check: ## 只检查文档链接、脚本语法与 hook/bridge 脚本一致性
	bash scripts/check.sh --docs

clean: ## 预览可清理的构建产物（真正删除加 --yes）
	bash scripts/clean.sh

clean-all: ## 清理构建产物、bridge 二进制与 dist（需重新构建）
	bash scripts/clean.sh --yes
