// Pin tool to obtain counts of loads and stores in region of interest demarcated by routine in a multi-threaded program
// Work derived from this stackoverflow answer: https://stackoverflow.com/a/62405749

#include <iostream>
#include <stdio.h>
#include "pin.H"
#include <string>
#include <vector>
#include <stack>
#include <unordered_map>
#include <algorithm>

// Specify max threads supported on PC
#define MAX_THREADS 512

FILE * trace;
// bool isROI[MAX_THREADS] = { false };
long int isROI[MAX_THREADS*8] = { 0 };
long long globalFuncID[MAX_THREADS*8];

// Lock serializes accesses to output
PIN_LOCK pinLock;

// Add variables for global read and write operations
unsigned long long int readCount[MAX_THREADS*8], writeCount[MAX_THREADS*8];
unsigned long long int readByteCount[MAX_THREADS*8], writeByteCount[MAX_THREADS*8];

// Track instruction operand registers
// static std::unordered_map<ADDRINT, REG> ins_base_reg_at;
static std::unordered_map<ADDRINT, std::string> str_of_ins_at;

// long long globalCount = 0;

// Create a struct for function stats
struct FuncStats{
    char* name;
    unsigned long long int readCount;
    unsigned long long int readByteCount;
    unsigned long long int writeCount;
    unsigned long long int writeByteCount;
    long long oldFuncID;
    // FIXME: add recursive depth counter to detect recuresion
    // and catch such cases as well
    // std::stack<unsigned long long int> reads;
    // std::stack<unsigned long long int> readBytes;
    // std::stack<unsigned long long int> writes;
    // std::stack<unsigned long long int> writeBytes;

    FuncStats(char* setname) : name(setname), readCount(0), readByteCount(0), writeCount(0), writeByteCount(0), oldFuncID(-1) {
    }
};

std::vector<FuncStats> functionData[MAX_THREADS*8];

// This routine is executed every time a thread is created.
VOID ThreadStart(THREADID threadid, CONTEXT* ctxt, INT32 flags, VOID* v)
{
    PIN_GetLock(&pinLock, threadid + 1);
    isROI[threadid*8] = 0;
    readCount[threadid*8] = 0;
    writeCount[threadid*8] = 0;
    readByteCount[threadid*8] = 0;
    writeByteCount[threadid*8] = 0;
    PIN_ReleaseLock(&pinLock);
}

// This routine is executed every time a thread is destroyed.
VOID ThreadFini(THREADID threadid, const CONTEXT* ctxt, INT32 code, VOID* v)
{
    PIN_GetLock(&pinLock, threadid + 1);
    for(auto it : functionData[threadid*8]) {
        fprintf(trace,"Thread %d\n", threadid);
        fprintf(trace,"Function:\t%s\n", it.name);
        fprintf(trace,"%s Reads:\t%llu\n", it.name, it.readCount);
        fprintf(trace,"%s Read Bytes:\t%llu\n", it.name, it.readByteCount);
        fprintf(trace,"%s Writes:\t%llu\n", it.name, it.writeCount);
        fprintf(trace,"%s Write Bytes:\t%llu\n", it.name, it.writeByteCount);
    }
    fprintf(trace,"Total Number of Reads:\t%llu\n", readCount[threadid*8]);
    fprintf(trace,"Total Number of Bytes Read:\t%llu\n", readByteCount[threadid*8]);
    fprintf(trace,"Total Number of Writes:\t%llu\n", writeCount[threadid*8]);
    fprintf(trace,"Total Number of Bytes Written:\t%llu\n", writeByteCount[threadid*8]);
    PIN_ReleaseLock(&pinLock);
}

// Print a memory read record
VOID RecordMemRead(ADDRINT ip, VOID * addr, UINT32 size, THREADID tid)
{
    // Return if not in ROI
    if(isROI[tid*8] <= 0)
    {
        return;
    }
    // Since we ignore all push and pop instructions,
    // is the following check needed?
    // if (ins_base_reg_at[ip] == LEVEL_BASE::REG_RSP) {
    //     return;
    // }

    // Print debug information
    // if(globalCount % 100000 == 2)
        // std::cout << size << " byte R@" << std::hex << ip << ": " << str_of_ins_at[ip] << "\n";

    // Log read count in CSV
    ++readCount[tid*8];
    readByteCount[tid*8] += size;
    if(globalFuncID[tid*8] > -1) {
        ++functionData[tid*8][globalFuncID[tid*8]].readCount;
        functionData[tid*8][globalFuncID[tid*8]].readByteCount += size;
    }
}

// Print a memory write record
// VOID RecordMemWrite(VOID * ip, VOID * addr, CHAR * rtn, THREADID tid)
VOID RecordMemWrite(ADDRINT ip, VOID * addr, UINT32 size, THREADID tid)
{
    // Return if not in ROI
    if(isROI[tid*8] <= 0)
    {
        return;
    }
    // if (ins_base_reg_at[ip] == LEVEL_BASE::REG_RSP) {
    //     return;
    // }

    // Print debug information
    // if(globalCount % 100000 == 2)
        // std::cout << size << " byte W@" << std::hex << ip << ": " << str_of_ins_at[ip] << "\n";

    // Log write count in CSV
    ++writeCount[tid*8];
    writeByteCount[tid*8] += size;
    if(globalFuncID[tid*8] > -1) {
        ++functionData[tid*8][globalFuncID[tid*8]].writeCount;
        functionData[tid*8][globalFuncID[tid*8]].writeByteCount += size;
    }
}

// Set ROI flag
VOID StartROI(THREADID tid, char* funcname)
{
    // isROI[tid] = true;
    // globalCount += 1;
    isROI[tid*8] += 1;
    for(size_t i = 0; i < functionData[tid*8].size(); i++) {
        if(strcmp(funcname, functionData[tid*8][i].name) == 0) {
            // recursive calls and nested ROIs may be a problem
            if (isROI[tid*8] > 0) {
                functionData[tid*8][i].oldFuncID = globalFuncID[tid*8];
            }
            globalFuncID[tid*8] = i;
            return;
        }
    }
    FuncStats newFunction(funcname);
    newFunction.oldFuncID = globalFuncID[tid*8];
    // size is one more than the last element
    // current size will be index of last element after pushing it
    globalFuncID[tid*8] = functionData[tid*8].size();
    functionData[tid*8].push_back(newFunction);
}

// Set ROI flag
VOID StopROI(THREADID tid, char* funcname)
{
    isROI[tid*8] -= 1;
    for(size_t i = 0; i < functionData[tid*8].size(); i++) {
        if(strcmp(funcname,functionData[tid*8][i].name) == 0) {
            globalFuncID[tid*8] = functionData[tid*8][i].oldFuncID;
            return;
        }
    }
}

// Is called for every instruction and instruments reads and writes
VOID Instruction(INS ins, VOID *v)
{
    // If the instruction is a call or return instruction, return
    if(INS_IsCall(ins) || INS_IsRet(ins))
        return;
    // If the instruction is a push or pop instruction, return
    OPCODE insOpcode = INS_Opcode(ins);
    if((insOpcode == XED_ICLASS_PUSH) || /* (insOpcode == XED_ICLASS_PUSH2) || (insOpcode == XED_ICLASS_PUSH2P) || */ (insOpcode == XED_ICLASS_PUSHA) || (insOpcode == XED_ICLASS_PUSHAD) || (insOpcode == XED_ICLASS_PUSHF) || (insOpcode == XED_ICLASS_PUSHFD) || (insOpcode == XED_ICLASS_PUSHFQ) /* || (insOpcode == XED_ICLASS_PUSHP) */)
        return;
    if((insOpcode == XED_ICLASS_POP) || /* (insOpcode == XED_ICLASS_POP2) || (insOpcode == XED_ICLASS_POP2P) || */ (insOpcode == XED_ICLASS_POPA) || (insOpcode == XED_ICLASS_POPAD) || (insOpcode == XED_ICLASS_POPF) || (insOpcode == XED_ICLASS_POPFD) || (insOpcode == XED_ICLASS_POPFQ) /* || (insOpcode == XED_ICLASS_POPP) */)
        return;

    // Instruments memory accesses using a predicated call, i.e.
    // the instrumentation is called iff the instruction will actually be executed.
    //
    // On the IA-32 and Intel(R) 64 architectures conditional moves and REP 
    // prefixed instructions appear as predicated instructions in Pin.
    UINT32 memOperands = INS_MemoryOperandCount(ins);

    // Iterate over each memory operand of the instruction.
    for (UINT32 memOp = 0; memOp < memOperands; memOp++)
    {
        // std::cout << "Ins: " << INS_Disassemble(ins) << std::endl;
        // std::cout << "Base Register: " << REG_StringShort(INS_OperandMemoryBaseReg(ins, INS_MemoryOperandIndexToOperandIndex(ins, memOp))) << std::endl;
        if (INS_OperandMemoryBaseReg(ins, INS_MemoryOperandIndexToOperandIndex(ins, memOp)) == LEVEL_BASE::REG_RSP) {
            continue;
        }
        str_of_ins_at[INS_Address(ins)] = INS_Disassemble(ins);
        if (INS_MemoryOperandIsRead(ins, memOp))
        {
            if(INS_OperandCount(ins) > 1)
                // ins_base_reg_at[INS_Address(ins)] = INS_OperandMemoryBaseReg(ins, INS_MemoryOperandIndexToOperandIndex(ins, memOp));
            INS_InsertPredicatedCall(
                ins, IPOINT_BEFORE, (AFUNPTR)RecordMemRead,
                IARG_INST_PTR,
                IARG_MEMORYOP_EA, memOp,
                IARG_MEMORYOP_SIZE, memOp,
                IARG_THREAD_ID,
                IARG_END);
        }
        // Note that in some architectures a single memory operand can be 
        // both read and written (for instance incl (%eax) on IA-32)
        // In that case we instrument it once for read and once for write.
        if (INS_MemoryOperandIsWritten(ins, memOp))
        {
            if(INS_OperandCount(ins) > 1)
                // ins_base_reg_at[INS_Address(ins)] = INS_OperandMemoryBaseReg(ins, INS_MemoryOperandIndexToOperandIndex(ins, memOp));
            INS_InsertPredicatedCall(
                ins, IPOINT_BEFORE, (AFUNPTR)RecordMemWrite,
                IARG_INST_PTR,
                IARG_MEMORYOP_EA, memOp,
                IARG_MEMORYOP_SIZE, memOp,
                IARG_THREAD_ID,
                IARG_END);
        }
    }
}

// Pin calls this function every time a new rtn is executed
void check_routine(RTN rtn, VOID *v)
{
    // Get routine name
    std::string ts_name = PIN_UndecorateSymbolName(RTN_Name(rtn), UNDECORATION_NAME_ONLY);

    if(ts_name.find("custom_roi_begin") != std::string::npos) {
        // Start tracing after ROI begin exec
        RTN_Open(rtn);
        RTN_InsertCall(rtn, IPOINT_AFTER, (AFUNPTR)StartROI, IARG_THREAD_ID, IARG_FUNCARG_ENTRYPOINT_VALUE, 0, IARG_END);
        RTN_Close(rtn);
    } else if (ts_name.find("custom_roi_end") != std::string::npos) {
        // Stop tracing before ROI end exec
        RTN_Open(rtn);
        RTN_InsertCall(rtn, IPOINT_BEFORE, (AFUNPTR)StopROI, IARG_THREAD_ID, IARG_FUNCARG_ENTRYPOINT_VALUE, 0, IARG_END);
        RTN_Close(rtn);
    }
}

// Pin calls this function at the end
VOID Fini(INT32 code, VOID *v)
{
    fclose(trace);
}

/* ===================================================================== */
/* Print Help Message                                                    */
/* ===================================================================== */

INT32 Usage()
{
    PIN_ERROR( "This Pintool prints a trace of memory addresses\n" 
              + KNOB_BASE::StringKnobSummary() + "\n");
    return -1;
}

/* ===================================================================== */
/* Main                                                                  */
/* ===================================================================== */

int main(int argc, char *argv[])
{
    // Initialize symbol table code, needed for rtn instrumentation
    PIN_InitSymbols();
    for(int i = 0; i < MAX_THREADS; i++) {
        globalFuncID[i*8] = -1;
    }

    // Usage
    if (PIN_Init(argc, argv)) return Usage();

    // Open trace file and write header
    trace = fopen("roitrace-mt.csv", "w");

    // Add instrument functions
    RTN_AddInstrumentFunction(check_routine, 0);
    INS_AddInstrumentFunction(Instruction, 0);

    // Counter initialization/dumps when a thread starts/ends
    PIN_AddThreadStartFunction(ThreadStart, 0);
    PIN_AddThreadFiniFunction(ThreadFini, 0);

    // Finish function called upon program termination
    PIN_AddFiniFunction(Fini, 0);

    // Never returns
    PIN_StartProgram();

    return 0;
}
