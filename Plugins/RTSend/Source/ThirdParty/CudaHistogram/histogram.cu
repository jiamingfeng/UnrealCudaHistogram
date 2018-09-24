#include <d3d11.h>
#include <cuda_d3d11_interop.h>
#include <cuda.h>
#include <builtin_types.h>
#include <cuda_runtime.h>
#include <sstream>
#include "cub/device/device_histogram.cuh"

extern "C"
std::string GenerateHistogram(ID3D11Texture2D* dxTexture, int width, int height, int* Histogram);

#define BIN_COUNT 256
#define HISTOGRAM_SIZE (BIN_COUNT * sizeof(unsigned int))

texture<uchar4, 2, cudaReadModeElementType> colorTex;

////////////////////////////////////////////////////////////////////////////////
// GPU-specific definitions
////////////////////////////////////////////////////////////////////////////////
//Fast mul on G8x / G9x / G100
#define IMUL(a, b) __mul24(a, b)

//Machine warp size
//G80's warp size is 32 threads
#define WARP_LOG2SIZE 5

//Warps in thread block for histogram256Kernel()
#define WARP_N 6

//Corresponding thread block size in threads for histogram256Kernel()
#define THREAD_N (WARP_N << WARP_LOG2SIZE)

//Total histogram size (in counters) per thread block for histogram256Kernel()
#define BLOCK_MEMORY (WARP_N * BIN_COUNT)

//Thread block count for histogram256Kernel()
#define BLOCK_N 64

#define TAG_MASK 0x07FFFFFFU//0x070707FFU//


////////////////////////////////////////////////////////////////////////////////
// If threadPos == threadIdx.x, there are always  4-way bank conflicts,
// since each group of 16 threads (half-warp) accesses different bytes,
// but only within 4 shared memory banks. Having shuffled bits of threadIdx.x
// as in histogram64GPU(), each half-warp accesses different shared memory banks
// avoiding any bank conflicts at all.
// Refer to the supplied whitepaper for detailed explanations.
////////////////////////////////////////////////////////////////////////////////
__device__ inline void addData256(volatile unsigned int *s_WarpHist, unsigned int data, unsigned int threadTag)
{
	unsigned int count;

	do
	{
		count = s_WarpHist[data] & TAG_MASK;
		count = threadTag | (count + 1);
		s_WarpHist[data] = count;
	} while (s_WarpHist[data] != count);
}

////////////////////////////////////////////////////////////////////////////////
// Main histogram calculation kernel
////////////////////////////////////////////////////////////////////////////////
static __global__ void histogramTex256Kernel(int *d_Result, unsigned int width, unsigned int height, int dataN)
{
	//Current global thread index
	const int    globalTid = IMUL(blockIdx.x, blockDim.x) + threadIdx.x;
	//Total number of threads in the compute grid
	const int   numThreads = IMUL(blockDim.x, gridDim.x);

	//Thread tag for addData256()
	//WARP_LOG2SIZE higher bits of counter values are tagged
	//by lower WARP_LOG2SIZE threadID bits
	const unsigned int threadTag = threadIdx.x << (32 - WARP_LOG2SIZE);

	//Shared memory storage for each warp
	volatile __shared__ unsigned int s_Hist[BLOCK_MEMORY];

	//Current warp shared memory base
	const int warpBase = (threadIdx.x >> WARP_LOG2SIZE) * BIN_COUNT;

	//Clear shared memory buffer for current thread block before processing
	for (int pos = threadIdx.x; pos < BLOCK_MEMORY; pos += blockDim.x)
		s_Hist[pos] = 0;

	//Cycle through the entire data set, update subhistograms for each warp
	__syncthreads();

	for (int pos = globalTid; pos < dataN; pos += numThreads)
	{
		// NOTE: check this... Not sure this is what needs to be done
		int py = pos / width;
		int px = pos - (py * width);
		uchar4 data4 = tex2D(colorTex, px, py);

		addData256(s_Hist + warpBase, (data4.x), threadTag);
		addData256(s_Hist + warpBase, (data4.y), threadTag);
		addData256(s_Hist + warpBase, (data4.z), threadTag);
		addData256(s_Hist + warpBase, (data4.w), threadTag);
	}

	__syncthreads();

	//Merge per-warp histograms into per-block and write to global memory
	for (int pos = threadIdx.x; pos < BIN_COUNT; pos += blockDim.x)
	{
		unsigned int sum = 0;

		for (int base = 0; base < BLOCK_MEMORY; base += BIN_COUNT)
			sum += s_Hist[base + pos] & TAG_MASK;

		d_Result[blockIdx.x * BIN_COUNT + pos] = int(sum);
	}
}

///////////////////////////////////////////////////////////////////////////////
// Merge BLOCK_N subhistograms of BIN_COUNT bins into final histogram
///////////////////////////////////////////////////////////////////////////////
// gridDim.x   == BIN_COUNT
// blockDim.x  == BLOCK_N
// blockIdx.x  == bin counter processed by current block
// threadIdx.x == subhistogram index
static __global__ void mergeHistogramTex256Kernel(int *d_Result)
{
	__shared__ int data[BLOCK_N];

	//Reads are uncoalesced, but this final stage takes
	//only a fraction of total processing time
	data[threadIdx.x] = d_Result[threadIdx.x * BIN_COUNT + blockIdx.x];

	for (int stride = BLOCK_N / 2; stride > 0; stride >>= 1)
	{
		__syncthreads();

		if (threadIdx.x < stride)
			data[threadIdx.x] += data[threadIdx.x + stride];
	}

	if (threadIdx.x == 0)
		d_Result[blockIdx.x] = data[0];
}

////////////////////////////////////////////////////////////////////////////////
// Host interface to GPU histogram
////////////////////////////////////////////////////////////////////////////////

extern "C"
void checkCudaError()
{
	cudaError_t err = cudaGetLastError();

	if (cudaSuccess != err)
	{
		fprintf(stderr, "Cuda error: %s.\n",
			cudaGetErrorString(err));
		exit(2);
	}
}

//Maximum block count for histogram64kernel()
//Limits input data size to 756MB
//const int MAX_BLOCK_N = 16384;

//Internal memory allocation
//const int BLOCK_N2 = 32;

std::string GenerateHistogram(ID3D11Texture2D* dxTexture, int width, int height, int* Histogram)
{

	static cudaGraphicsResource *cudaResource = nullptr;
	static ID3D11Texture2D* cudaTexture = nullptr;
	static int *d_histogram = nullptr;
	size_t HistogramSize = BIN_COUNT * sizeof(int);

	if (!cudaResource || cudaTexture != dxTexture)
	{
		cudaGraphicsD3D11RegisterResource(&cudaResource, dxTexture,
			cudaGraphicsRegisterFlagsNone);

		cudaTexture = dxTexture;
		cudaMalloc(&d_histogram, HistogramSize * 64);
	}

	cudaGraphicsMapResources(1, &cudaResource);

	cudaArray *cuArray = nullptr;
	cudaGraphicsSubResourceGetMappedArray(&cuArray, cudaResource, 0, 0);

	cudaBindTextureToArray(colorTex, cuArray);	

	histogramTex256Kernel << <BLOCK_N, THREAD_N >> > (d_histogram, width, height, width *height / 4);
	checkCudaError();

	mergeHistogramTex256Kernel << <BIN_COUNT, BLOCK_N >> > (d_histogram);
	checkCudaError();

	cudaUnbindTexture(colorTex);
	checkCudaError();

	cudaMemcpy(Histogram, d_histogram, HistogramSize, cudaMemcpyDeviceToHost);
	//cudaFree(d_histogram);

	cudaGraphicsUnmapResources(1, &cudaResource);

	//cudaUnbindTexture(ColorBuffer);

	////Allocate device and host memory for histogram
	//int *d_histogram[1];
	//size_t HistogramSize = 256 * sizeof(int);
	//cudaMalloc(&d_histogram[0], HistogramSize);

	//int num_levels[1] = { 256 };
	//int lower_level[1] = { 0 };        // lower sample value boundary of lowest bin)
	//int upper_level[1] = { 255 };    // (upper sample value boundary of upper bin)

	//int num_row_samples = width;
	//int num_rows = height;
	//int num_pixels = width * height;
	//size_t row_stride_bytes = num_row_samples * sizeof(unsigned char) * 4;


	//// Determine temporary device storage requirements
	//void *d_temp_storage = NULL;
	//size_t temp_storage_bytes = 0;
	//cub::DeviceHistogram::MultiHistogramEven<4, 1>(d_temp_storage, temp_storage_bytes,
	//	cudaTexture, d_histogram, num_levels, lower_level, upper_level,
	//	num_pixels);// num_row_samples, num_rows, row_stride_bytes);


	//				// Allocate temporary storage
	//cudaMalloc(&d_temp_storage, temp_storage_bytes);

	//// Compute histograms
	//cub::DeviceHistogram::MultiHistogramEven<4, 1>(d_temp_storage, temp_storage_bytes,
	//	cudaTexture, d_histogram, num_levels, lower_level, upper_level,
	//	num_pixels);//num_row_samples, num_rows, row_stride_bytes);

	//cudaMemcpy(Histogram, d_histogram[0], HistogramSize, cudaMemcpyDeviceToHost);

	//// Unmap and unregister the graphics resource
	//cudaGraphicsUnmapResources(1, &cudaResource);
	//cudaGraphicsUnregisterResource(cudaResource);

	//cudaFree(d_temp_storage);
	//cudaFree(d_histogram[0]);

	return {};
}