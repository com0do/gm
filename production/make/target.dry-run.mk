# target.dry-run.mk - shared DRY_RUN=1 short-circuit for target.<type>.mk

.PHONY: $(TARGET)
$(TARGET):
	@[ -s $(TARGET_DEP) ] || echo > $(TARGET_DEP)
	@if [ -n "$(DRY_DEPS)" ]; then \
	    sed -i "/^$(TARGET):/{h;s/:.*/:$(DRY_DEPS)/};\$${x;/^\$$/{s//$(TARGET):$(DRY_DEPS)/;H};x}" $(TARGET_DEP); \
	 else \
	    sed -i '/^$(TARGET):/d' $(TARGET_DEP); \
	 fi
ifneq ($(DRY_REVERSE_PREFIX),)
	@[ -s $(DRY_REVERSE_FILE) ] || echo > $(DRY_REVERSE_FILE)
	@sed -i '/^$(DRY_REVERSE_PREFIX)_/ { s/\<$(TARGET)\>//g; s/  */ /g; s/ *$$//; /:=$$/d; }' $(DRY_REVERSE_FILE)
	@[ -s $(DRY_REVERSE_FILE) ] || echo > $(DRY_REVERSE_FILE)
	@for d in $(DRY_DEPS); do \
	    case "$$d" in pkg-*) continue ;; esac ; \
	    sed -i "/^$(DRY_REVERSE_PREFIX)_$$d := /{h;s/\$$/ $(TARGET)/};\$${x;/^\$$/{s//$(DRY_REVERSE_PREFIX)_$$d := $(TARGET)/;H};x}" $(DRY_REVERSE_FILE); \
	done
endif
