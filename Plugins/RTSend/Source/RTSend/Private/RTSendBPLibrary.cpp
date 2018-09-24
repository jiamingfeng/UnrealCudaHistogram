// Copyright 1998-2018 Epic Games, Inc. All Rights Reserved.

#include "RTSendBPLibrary.h"

#if PLATFORM_WINDOWS
#include "AllowWindowsPlatformTypes.h"
#endif
#include <d3d11.h>
#if PLATFORM_WINDOWS
#include "HideWindowsPlatformTypes.h"
#endif

#include "Engine/TextureRenderTarget2D.h"
#include "GPUHistogram.h"
#include "RTSend.h"

static ID3D11Device* g_D3D11Device = nullptr;
static ID3D11DeviceContext* g_pImmediateContext = nullptr;

URTSendBPLibrary::URTSendBPLibrary(const FObjectInitializer& ObjectInitializer)
: Super(ObjectInitializer)
{

}

bool URTSendBPLibrary::ComputeHistogram(const UTextureRenderTarget2D* RenderTarget, TArray<int32>& Histogram)
{
	//UTextureRenderTarget2D* RenderTarget = nullptr;

	if (g_D3D11Device == nullptr || g_pImmediateContext == nullptr)
	{
		g_D3D11Device = (ID3D11Device*)GDynamicRHI->RHIGetNativeDevice();
		g_D3D11Device->GetImmediateContext(&g_pImmediateContext);
	}

	ID3D11Texture2D* dxTexture = nullptr;

	if (RenderTarget == nullptr)
	{
		dxTexture = (ID3D11Texture2D*)GEngine->GameViewport->Viewport->GetRenderTargetTexture()->GetNativeResource();
	}
	else
	{
		dxTexture = (ID3D11Texture2D*)RenderTarget->Resource->TextureRHI->GetTexture2D()->GetNativeResource();
	}
		

	if (dxTexture == nullptr) {
		UE_LOG(RTLog, Warning, TEXT("Viewport RT is null!!"));
		return false;
	}

	D3D11_TEXTURE2D_DESC td;
	dxTexture->GetDesc(&td);

	static ID3D11Texture2D * targetTex = nullptr;
	static D3D11_TEXTURE2D_DESC desc;

	if (targetTex == nullptr ||
		desc.Width != td.Width ||
		desc.Height != td.Height)
	{
		ZeroMemory(&desc, sizeof(D3D11_TEXTURE2D_DESC));
		desc.Width = td.Width;
		desc.Height = td.Height;
		desc.MipLevels = 1;
		desc.ArraySize = 1;
		desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
		desc.SampleDesc.Count = 1;
		desc.Usage = D3D11_USAGE_DEFAULT;
		desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;

		if (FAILED(g_D3D11Device->CreateTexture2D(&desc, NULL, &targetTex)))
		{
			return false;
		}
	}
	
	//int* HistogramData = Histogram.GetData();

	ENQUEUE_UNIQUE_RENDER_COMMAND_TWOPARAMETER(
		HistogramCompute,
		ID3D11Texture2D*, dst, targetTex,
		ID3D11Texture2D*, src, dxTexture,
		{

			g_pImmediateContext->CopyResource(dst, src);
			g_pImmediateContext->Flush();

			

		});

	Histogram.SetNum(256);
	std::string errorString = GetHistogram(targetTex, td.Width, td.Height, Histogram.GetData());
	UE_LOG(RTLog, Error, TEXT("Cuda Error: %s"), errorString.c_str());


	return true;

}

