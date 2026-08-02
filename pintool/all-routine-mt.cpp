// Pin tool to obtain counts of loads and stores in region of interest demarcated by routine in a multi-threaded program
// Work derived from this stackoverflow answer: https://stackoverflow.com/a/62405749

#include <stdio.h>
#include "pin.H"
#include <string>
#include <vector>
#include <stack>

// Specify max threads supported on PC
#define MAX_THREADS 12

FILE * trace;

// Lock serializes accesses to output
PIN_LOCK pinLock;

// Add variables for global read and write operations
unsigned long long int readCount[MAX_THREADS], writeCount[MAX_THREADS];
unsigned long long int readByteCount[MAX_THREADS], writeByteCount[MAX_THREADS];

// This routine is executed every time a thread is created.
VOID ThreadStart(THREADID threadid, CONTEXT* ctxt, INT32 flags, VOID* v)
{
    PIN_GetLock(&pinLock, threadid + 1);
    readCount[threadid] = 0;
    writeCount[threadid] = 0;
    readByteCount[threadid] = 0;
    writeByteCount[threadid] = 0;
    PIN_ReleaseLock(&pinLock);
}

// This routine is executed every time a thread is destroyed.
VOID ThreadFini(THREADID threadid, const CONTEXT* ctxt, INT32 code, VOID* v)
{
    PIN_GetLock(&pinLock, threadid + 1);
    fprintf(trace,"[Thread %d] Total Number of Reads:\t%llu\n", threadid, readCount[threadid]);
    fprintf(trace,"[Thread %d] Total Number of Bytes Read:\t%llu\n", threadid, readByteCount[threadid]);
    fprintf(trace,"[Thread %d] Total Number of Writes:\t%llu\n", threadid, writeCount[threadid]);
    fprintf(trace,"[Thread %d] Total Number of Bytes Written:\t%llu\n", threadid, writeByteCount[threadid]);
    PIN_ReleaseLock(&pinLock);
}

// Print a memory read record
VOID RecordMemRead(VOID * ip, VOID * addr, UINT32 size, THREADID tid)
{
    // Log read count in CSV
    readCount[tid]++;
    readByteCount[tid] += size;
}

// Print a memory write record
// VOID RecordMemWrite(VOID * ip, VOID * addr, CHAR * rtn, THREADID tid)
VOID RecordMemWrite(VOID * ip, VOID * addr, UINT32 size, THREADID tid)
{
    // Log write count in CSV
    writeCount[tid]++;
    writeByteCount[tid] += size;
}

// Is called for every instruction and instruments reads and writes
VOID Instruction(INS ins, VOID *v)
{
    // Instruments memory accesses using a predicated call, i.e.
    // the instrumentation is called iff the instruction will actually be executed.
    //
    // On the IA-32 and Intel(R) 64 architectures conditional moves and REP 
    // prefixed instructions appear as predicated instructions in Pin.
    UINT32 memOperands = INS_MemoryOperandCount(ins);

    // Iterate over each memory operand of the instruction.
    for (UINT32 memOp = 0; memOp < memOperands; memOp++)
    {
        if (INS_MemoryOperandIsRead(ins, memOp))
        {
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

    // Usage
    if (PIN_Init(argc, argv)) return Usage();

    // Open trace file and write header
    trace = fopen("all-routine-mt.csv", "w");

    // Add instrument functions
    // RTN_AddInstrumentFunction(check_routine, 0);
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
