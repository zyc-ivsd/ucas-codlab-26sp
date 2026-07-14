
#ifndef __PERF_CNT__
#define __PERF_CNT__

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Result {
	int pass;
	unsigned long msec;
	unsigned long cycles;  
	unsigned long mem_cycles;
	unsigned long retired_cycles;
} Result;

void bench_prepare(Result *res);
void bench_done(Result *res);

#ifdef __cplusplus
}
#endif

#endif
