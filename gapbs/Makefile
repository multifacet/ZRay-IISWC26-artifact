# See LICENSE.txt for license details.
CXX=$(CUSTOM_CC)

#CXX_FLAGS += -std=c++11 -O2 -Wall# -fno-inline
#ZRAY_LINK_FLAGS = -std=c++11 -Wall# -fno-inline
CXX_FLAGS += -std=c++11 -O2 -Wall #-Xclang -no-opaque-pointers
ZRAY_LINK_FLAGS = -std=c++11 -O2 #-Wall -Xclang -no-opaque-pointers
PAR_FLAG = -fopenmp=libomp

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

# Extra flags passed to the ZRay opt pass.
ZRAY_PASS_FLAGS ?=

# Uninstrumented binaries used as the timing/RSS baseline. Same sources and same
# optimization pipeline as the default build, but without the ZRay pass, so the only
# difference is the instrumentation itself. The ZRAY_ROI markers are inline asm
# comments that emit no code, so they are left in place: both builds then carry the
# same optimization barriers and the comparison isolates ZRay's counters.
KERNELS_BASELINE = $(addsuffix -baseline,$(KERNELS))

.PHONY: all baseline
all: $(SUITE)

baseline: $(KERNELS_BASELINE)

$(KERNELS): % : src/%_linked.ll
	cd $*; $(CXX) -L/usr/lib/llvm-15/lib/ $(ZRAY_LINK_FLAGS) ../$< -o $@

# No zray_runtime.ll is linked here: without the pass there are no counter calls.
$(KERNELS_BASELINE): %-baseline : src/%_baseline_optimized.ll
	cd $*; $(CXX) -L/usr/lib/llvm-15/lib/ $(ZRAY_LINK_FLAGS) ../$< -o $@

src/%_linked.ll : src/%_optimized.ll $(ZRAY_BIN_PATH)/zray_runtime.ll
	$(CUSTOM_LINK) $^ -S -o $@

src/%_optimized.ll : src/%.ll
	mkdir -p $*
	cd $*; $(CUSTOM_OPT) -enable-new-pm=0 -O2 -mem2reg -load $(ZRAY_BIN_PATH)/libzray.so -zray $(ZRAY_PASS_FLAGS) ../$< -o ../$@

src/%_baseline_optimized.ll : src/%.ll
	mkdir -p $*
	cd $*; $(CUSTOM_OPT) -enable-new-pm=0 -O2 -mem2reg ../$< -o ../$@

src/%.ll : src/%.cc src/*.h
	$(CXX) $(CXX_FLAGS) -S -emit-llvm $< -o $@
	#$(CXX) $(CXX_FLAGS) -I/usr/include/clang/15/include -S -emit-llvm $< -o $@

# Converter does not need instrumentation and is compiled directly in the Makefile directory
converter: src/converter.cc $(HEADERS)
	$(CXX) $(CXX_FLAGS) $< -o $@

# Testing
include test/test.mk

# Benchmark Automation
include benchmark/bench.mk


.PHONY: clean
clean:
	rm -rf $(SUITE) test/out/* src/*.ll
