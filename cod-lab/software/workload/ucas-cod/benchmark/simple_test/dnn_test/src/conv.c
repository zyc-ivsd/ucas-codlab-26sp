#include "printf.h"
#include "trap.h"
#include "mul.h"
#include "div.h"
#include "perf_cnt.h"

#define FRAC_BIT 10

#define RD_ADDR 135106448
#define RD_SIZE_D0 1
#define RD_SIZE_D1 1
#define RD_SIZE_D2 28
#define RD_SIZE_D3 28

#define WEIGHT_ADDR 134217728
#define WEIGHT_SIZE_D0 20
#define WEIGHT_SIZE_D1 1
#define WEIGHT_SIZE_D2 5
#define WEIGHT_SIZE_D3 5

#define WR_ADDR 135108240
#define WR_SIZE_D0 1
#define WR_SIZE_D1 20
#define WR_SIZE_D2 12
#define WR_SIZE_D3 12

#define KERN_ATTR_CONV_PAD 0
#define KERN_ATTR_CONV_STRIDE 1
#define KERN_ATTR_POOL_PAD 0
#define KERN_ATTR_POOL_KERN_SIZE 2
#define KERN_ATTR_POOL_STRIDE 2

//MMIO register address of DNN accelerator
#define GPIO_START_ADDR    0x60030000
#define GPIO_DONE_ADDR     0x60030008

struct size_vec4
{
	unsigned d0;
	unsigned d1;
	unsigned d2;
	unsigned d3;
};

struct mem_addr
{
	unsigned rd_addr;
	unsigned weight_addr;
	unsigned wr_addr;
};

int mul(short a, short b)
{
#ifndef USE_MUL
	int ans = mul_ll(a, b);
#else
	int ans = a * b;
#endif
	return ans;
}

struct mem_addr addr = {RD_ADDR, WEIGHT_ADDR, WR_ADDR};
struct size_vec4 rd_size = {RD_SIZE_D0, RD_SIZE_D1, RD_SIZE_D2, RD_SIZE_D3};
struct size_vec4 wr_size = {WR_SIZE_D0, WR_SIZE_D1, WR_SIZE_D2, WR_SIZE_D3};
struct size_vec4 weight_size = {WEIGHT_SIZE_D0, WEIGHT_SIZE_D1, WEIGHT_SIZE_D2, WEIGHT_SIZE_D3};

struct size_vec4 conv_size;

extern char _binary_data_result_bin_start[];
extern char _binary_data_result_bin_size[];

void convolution()
{
	short *in = (short *)addr.rd_addr;
	short *weight = (short *)addr.weight_addr;
	short *out = (short *)addr.wr_addr;

	unsigned batch = rd_size.d0;
	unsigned input_ch = rd_size.d1;
	unsigned input_fm_h = rd_size.d2;
	unsigned input_fm_w = rd_size.d3;

	unsigned output_ch = weight_size.d0;
	unsigned weight_ch = weight_size.d1;
	unsigned kernel_h = weight_size.d2;
	unsigned kernel_w = weight_size.d3;

	unsigned pad = KERN_ATTR_CONV_PAD;
	unsigned pad_len = pad << 1;

	unsigned stride = KERN_ATTR_CONV_STRIDE;

	unsigned conv_out_w = input_fm_w - kernel_w + pad_len;
	unsigned conv_out_h = input_fm_h - kernel_h + pad_len;

	conv_out_w = div(conv_out_w, stride);
	conv_out_h = div(conv_out_h, stride);

	conv_out_w++;
	conv_out_h++;   //24 

	conv_size.d0 = wr_size.d0;
	conv_size.d1 = wr_size.d1;
	conv_size.d2 = conv_out_h;
	conv_size.d3 = conv_out_w;

	unsigned filter_stride = weight_ch * (1 + kernel_h * kernel_w);

	for (unsigned b = 0; b < batch; b++) {
		unsigned batch_in_offset = b * input_ch * input_fm_h * input_fm_w;
		unsigned batch_out_offset = b * output_ch * conv_out_h * conv_out_w;

		for (unsigned oc = 0; oc < output_ch; oc++) {
			short *filter_base = weight + oc * filter_stride;
			short bias = filter_base[0];

			for (unsigned oh = 0; oh < conv_out_h; oh++) {
				for (unsigned ow = 0; ow < conv_out_w; ow++) {
					long long acc = 0;

					for (unsigned ic = 0; ic < input_ch; ic++) {
						unsigned ic_weight_off = ic * (1 + kernel_h * kernel_w);
						unsigned ic_in_off = ic * input_fm_h * input_fm_w;

						for (unsigned kh = 0; kh < kernel_h; kh++) {
							for (unsigned kw = 0; kw < kernel_w; kw++) {
								int ih = (int)(oh * stride + kh) - (int)pad;
								int iw = (int)(ow * stride + kw) - (int)pad;

								if (ih >= 0 && ih < (int)input_fm_h &&
								    iw >= 0 && iw < (int)input_fm_w) {
									short input_val = in[batch_in_offset + ic_in_off
									                      + ih * input_fm_w + iw];
									short weight_val = filter_base[ic_weight_off + 1
									                      + kh * kernel_w + kw];
									acc += (long long)mul(input_val, weight_val);
								}
							}
						}
					}

					int result = (int)(acc >> FRAC_BIT) + bias;
					if (result > 32767) result = 32767;
					if (result < -32768) result = -32768;

					out[batch_out_offset + oc * conv_out_h * conv_out_w
					    + oh * conv_out_w + ow] = (short)result;
				}
			}
		}
	}
}

void pooling()
{
	short *out = (short *)addr.wr_addr;

	unsigned batch = conv_size.d0;
	unsigned input_ch = conv_size.d1;
	unsigned input_fm_h = conv_size.d2;
	unsigned input_fm_w = conv_size.d3;

	unsigned pad = KERN_ATTR_POOL_PAD;
	unsigned pad_len = pad << 1;

	unsigned pad_w_test = input_fm_w - KERN_ATTR_POOL_KERN_SIZE;
	unsigned pad_h_test = input_fm_h - KERN_ATTR_POOL_KERN_SIZE;

	unsigned pool_out_w = pad_w_test + pad_len;
	unsigned pool_out_h = pad_h_test + pad_len;

	unsigned stride = KERN_ATTR_POOL_STRIDE;

	unsigned pad_w_test_remain = pad_w_test - mul(div(pad_w_test, stride), stride);
	unsigned pad_h_test_remain = pad_h_test - mul(div(pad_h_test, stride), stride);

	pool_out_w = div(pool_out_w, stride);
	pool_out_h = div(pool_out_h, stride);
	pool_out_w++;
	pool_out_h++;

	if ((!pad) && (pad_w_test_remain || pad_h_test_remain))
	{
		pool_out_w++;
		pool_out_h++;
	}

	unsigned kern_size = KERN_ATTR_POOL_KERN_SIZE;

	for (unsigned b = 0; b < batch; b++) {
		unsigned batch_in_offset = b * input_ch * input_fm_h * input_fm_w;
		unsigned batch_out_offset = b * input_ch * pool_out_h * pool_out_w;

		for (unsigned ic = 0; ic < input_ch; ic++) {
			unsigned ch_in_offset = ic * input_fm_h * input_fm_w;
			unsigned ch_out_offset = ic * pool_out_h * pool_out_w;

			for (unsigned oh = 0; oh < pool_out_h; oh++) {
				for (unsigned ow = 0; ow < pool_out_w; ow++) {
					short max_val = -32768;
					int has_valid = 0;

					for (unsigned kh = 0; kh < kern_size; kh++) {
						for (unsigned kw = 0; kw < kern_size; kw++) {
							int ih = (int)(oh * stride + kh) - (int)pad;
							int iw = (int)(ow * stride + kw) - (int)pad;

							if (ih >= 0 && ih < (int)input_fm_h &&
							    iw >= 0 && iw < (int)input_fm_w) {
								short val = out[batch_in_offset + ch_in_offset
								                + ih * input_fm_w + iw];
								if (val > max_val) max_val = val;
								has_valid = 1;
							}
						}
					}

					if (!has_valid) max_val = 0;

					out[batch_out_offset + ch_out_offset
					    + oh * pool_out_w + ow] = max_val;
				}
			}
		}
	}
}

#ifdef USE_HW_ACCEL
void launch_hw_accel()
{
	volatile int* gpio_start = (void*)(GPIO_START_ADDR);
	volatile int* gpio_done = (void*)(GPIO_DONE_ADDR);

	*gpio_start = 1;

	while ((*gpio_done & 0x1) == 0)
		;
}
#endif

int comparing()
{
	char *out = (char *)addr.wr_addr;
	char *result = (char *)_binary_data_result_bin_start;

#ifdef USE_HW_ACCEL
	int count = (int)_binary_data_result_bin_size + 
		    (16 - WR_SIZE_D3) * 2 * WR_SIZE_D2 * WR_SIZE_D1;
#else
	int count = (int)_binary_data_result_bin_size;
#endif

	for (int i = 0, j = 0; i < count; i++)
	{
#ifdef USE_HW_ACCEL
		int alignment = i & 0x0000001f;
		if (alignment >= (WR_SIZE_D3 << 1))
			continue;
#endif
		if (*(out + i) != *(result + j))
		{
			printf("Failed! at address %x and %x with data %x and %x\n", out + i, result + j, *(out + i), *(result + j));
			return 1;
		}
		j++;
	}

	printf("Passed!\n");
	return 0;
}

int main()
{
	Result res;
	bench_prepare(&res);

#ifdef USE_HW_ACCEL
	printf("Launching task...\n");
	launch_hw_accel();
#else
	printf("starting convolution\n");
	convolution();
	printf("starting pooling\n");
	pooling();
#endif

	bench_done(&res);
	printf("msec = %u, cycles = %u, inst_retired = %u, mem_req = %u\n",
	       (unsigned int)res.msec,
	       (unsigned int)res.cycles,
	       (unsigned int)res.mem_cycles,
	       (unsigned int)res.retired_cycles);

	int result = comparing();
	printf("benchmark finished\n");

	if (result == 0) {
		hit_good_trap();
	} else {
		nemu_assert(0);
	}

	return 0;
}
