# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Michael Rogenmoser <michaero@iis.ee.ethz.ch>

#	vopt $(PA_FLAGS) +acc -o vopt_tb axi_memory_island_tb -work work

MEMORY_ISLAND_ROOT := $(CURDIR)

BENDER ?= bender -d $(MEMORY_ISLAND_ROOT)

#QUESTA ?= questa-2019.3
#QUESTA ?= questa-2021.3
#QUESTA ?= questa-2022.3
QUESTA ?= questa-2025.1


VSIM ?= $(QUESTA) vsim
VCS ?= $(QUESTA) vcs
VLOGAN ?= $(QUESTA) vlogan

#PA_FLAGS = -pa_top axi_memory_island_tb/i_dut -pa_upf $(MEMORY_ISLAND_ROOT)/upf/memis_tb.upf -pa_enable=highlight -pa_coverage=powerstate -pa_enable=highlight+debug -L mtiPA -pa_genrpt=pa+de+cell+srcsink -pa_checks=s+i+r -pa_disable=defaultoff
PA_FLAGS = -pa_top axi_memory_island_tb/i_dut -pa_upf $(MEMORY_ISLAND_ROOT)/upf/memis_tb.upf -pa_enable=highlight -pa_coverage=powerstate -pa_enable=highlight+debug -L mtiPA -pa_genrpt=pa+de+cell+srcsink -pa_checks=s+i+r -pa_disable=defaultoff -pa_upfversion=3.0

scripts/compile.tcl: Bender.yml Bender.lock
	$(BENDER) script vsim -t test --vlog-arg="-svinputport=compat" > $@
	echo "return 0" >> $@

.PHONY: test-vsim
test-vsim: scripts/compile.tcl
	$(VSIM) -64 -c -do "quit -code [source scripts/compile.tcl]"
	$(VSIM) -64 -do "vsim axi_memory_island_tb -voptargs=+acc; do scripts/debug_wave.do"

test-vsim-bare: scripts/compile.tcl
	$(VSIM) -64 -c -do "quit -code [source scripts/compile.tcl]"
	$(VSIM) -64 -c -do "vsim axi_memory_island_tb; run -all"

test-vsim-pw:scripts/compile.tcl
	$(VSIM) -64 -c -do "quit -code [source scripts/compile.tcl]"
	$(VSIM) -64 -do "vsim -c axi_memory_island_tb -pa -pa_highlight -t 1ps -vopt -voptargs=\"+acc ${PA_FLAGS}\";"

## Internal CI
NONFREE_REMOTE ?= git@iis-git.ee.ethz.ch:pulp-restricted/memory_island_nonfree.git
NONFREE_COMMIT ?= master

nonfree-init:
	git clone $(NONFREE_REMOTE) $(MEMORY_ISLAND_ROOT)/nonfree
	cd nonfree && git checkout $(NONFREE_COMMIT)

-include $(MEMORY_ISLAND_ROOT)/nonfree/nonfree.mk

BENDER_FILES := $(shell $(BENDER) script flist -n -t test -t memory_island_standalone_synth)

.PHONY: format
format:
	verible-verilog-format $(BENDER_FILES) --inplace --flagfile .verilog_format


VCS_FLAGS ?= -full64 -nc -ignore initializer_driver_checks -assert disable_cover -kdb -Mlib=$(VCS_BUILDDIR)
VLOGAN_ARGS += -full64 -q -ntb_opts uvm -kdb -nc -assert svaext +v2k -timescale=1ps/1ps -incr_vlogan $(TRACE_FLAGS_VCS)

$(MEMORY_ISLAND_ROOT)/build:
	mkdir -p $@

$(MEMORY_ISLAND_ROOT)/build/compile-vcs: $(MEMORY_ISLAND_ROOT)/build
	$(BENDER) script vcs -t test --vlog-arg="$(VLOGAN_ARGS)" --vlogan-bin "$(VLOGAN)" > $@
	chmod +x $@

$(MEMORY_ISLAND_ROOT)/build/vcs.bin: $(MEMORY_ISLAND_ROOT)/build/compile-vcs
	cd $(MEMORY_ISLAND_ROOT)/build && \
	sh $< && \
	$(VCS) -top axi_memory_island_tb $(VCS_FLAGS) -o $@

.PHONY: test-vcs test-vcs-clean
test-vcs: $(MEMORY_ISLAND_ROOT)/build/vcs.bin
	cd $(MEMORY_ISLAND_ROOT)/build && \
	$<

test-vcs-clean:
	rm -rf $(MEMORY_ISLAND_ROOT)/build
