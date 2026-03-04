# Regenerate yt.solver.core.js and yt.solver.lib.js from yt-dlp/ejs
# Requires one of: npm, pnpm, deno, or bun

EJS_REPO   := https://github.com/yt-dlp/ejs.git
EJS_DIR    := ejs
DATA_DIR   := data

.PHONY: update-solver clean-solver

update-solver:
	@if [ -d "$(EJS_DIR)" ]; then \
		echo "Updating existing yt-dlp/ejs checkout..."; \
		git -C "$(EJS_DIR)" pull --ff-only; \
	else \
		echo "Cloning yt-dlp/ejs..."; \
		git clone --depth 1 "$(EJS_REPO)" "$(EJS_DIR)"; \
	fi
	@cd "$(EJS_DIR)" && python3 hatch_build.py
	cp "$(EJS_DIR)/dist/yt.solver.core.js" "$(DATA_DIR)/yt.solver.core.js"
	cp "$(EJS_DIR)/dist/yt.solver.lib.js"  "$(DATA_DIR)/yt.solver.lib.js"
	@echo "✓ Solver JS files updated"

clean-solver:
	rm -rf "$(EJS_DIR)"
