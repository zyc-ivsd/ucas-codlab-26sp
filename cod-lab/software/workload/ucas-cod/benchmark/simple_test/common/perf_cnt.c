#include "perf_cnt.h"
#define PERF_CNT_0_BASE  0x60010000

// add read cnt function
static inline unsigned long read_perf_cnt(int id) {
  volatile unsigned int *base = (volatile unsigned int *)(0x60010000 +(id/2)*0x1000);
  return base[(id %2)*2];  
}


unsigned long _uptime() {
  return read_perf_cnt(0); 
}


void bench_prepare(Result *res) {
  // TODO [COD]
  //   Add preprocess code, record performance counters' initial states.
  //   You can communicate between bench_prepare() and bench_done() through
  //   static variables or add additional fields in `struct Result`
  res->msec = _uptime();
  res->cycles = read_perf_cnt(0); 
  res->mem_cycles = read_perf_cnt(1); 
  res->retired_cycles = read_perf_cnt(2);
}

void bench_done(Result *res) {
  // TODO [COD]
  //  Add postprocess code, record performance counters' current states.
  res->msec = _uptime() - res->msec;
  res->cycles = read_perf_cnt(0) - res->cycles; 
  res->mem_cycles = read_perf_cnt(1) - res->mem_cycles;
  res->retired_cycles = read_perf_cnt(2) - res->retired_cycles; 
}

