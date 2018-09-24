#pragma once
#include <string>

struct ID3D11Texture2D;

std::string GetHistogram(ID3D11Texture2D* dxTexture, int width, int height, int* Histogram);
