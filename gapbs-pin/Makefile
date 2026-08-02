# See LICENSE.txt for license details.
CXX=$(CUSTOM_CC)

CXX_FLAGS += -std=c++11 -O2 -Wall# -fno-inline
PAR_FLAG = -fopenmp=libomp
ZRAY_LINK_FLAGS = -std=c++11 -Wall# -fno-inline

ifneq (,$(findstring icpc,$(CXX)))
	PAR_FLAG = -openmp
endif

ifneq (,$(findstring sunCC,$(CXX)))
	CXX_FLAGS = -std=c++11 -xO3 -m64 -xtarget=native
	PAR_FLAG = -xopenmp
endif

ifneq ($(SERIAL), 1)
	CXX_FLAGS += $(PAR_FLAG)
	ZRAY_LINK_FLAGS += $(PAR_FLAG)
endif

KERNELS = bc bfs cc cc_sv pr pr_spmv sssp tc
SUITE = $(KERNELS) converter

.PHONY: all
all: $(SUITE)

$(KERNELS): % : src/%_optimized.ll
	cd $*; $(CXX) -L/usr/lib/llvm-15/lib/ -L$(PIN_ROI_DIR) $(ZRAY_LINK_FLAGS) ../$< -lpinroi-cc -o $@

#src/%_linked.ll : src/%_optimized.ll $(ZRAY_BIN_PATH)/tool_dyn.ll
	#$(CUSTOM_LINK) $^ -S -o $@

src/%_optimized.ll : src/%.ll
	mkdir -p $*
	cd $*; $(CUSTOM_OPT) -enable-new-pm=0 -O2 -mem2reg ../$< -o ../$@
	#cd $*; $(CUSTOM_OPT) -enable-new-pm=0 -O2 -mem2reg -load $(ZRAY_BIN_PATH)/tool.so -tool_pass ../$< -o ../$@

src/%.ll : src/%.cc src/*.h
	$(CXX) $(CXX_FLAGS) -I$(PIN_ROI_DIR) -S -emit-llvm $< -o $@

# Converter does not need instrumentation and is compiled directly in the Makefile directory
converter: src/converter.cc $(HEADERS)
	$(CXX) $(CXX_FLAGS) -I$(PIN_ROI_DIR) $< -o $@

# Testing
include test/test.mk

# Benchmark Automation
include benchmark/bench.mk


.PHONY: clean
clean:
	rm -rf $(SUITE) test/out/* src/*.ll
