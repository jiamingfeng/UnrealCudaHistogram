#include "GPUHistogram.h"

extern "C"
std::string GenerateHistogram(ID3D11Texture2D* dxTexture, int width, int height, int* Histogram);

std::string GetHistogram(ID3D11Texture2D* dxTexture, int width, int height, int* Histogram)
{
	return GenerateHistogram(dxTexture, width, height, Histogram);
}
