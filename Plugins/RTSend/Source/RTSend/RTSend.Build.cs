// Some copyright should be here...

using UnrealBuildTool;
using System.IO;

public class RTSend : ModuleRules
{

    private string ThirdPartyPath
    {
        get { return Path.GetFullPath(Path.Combine(ModuleDirectory, "../ThirdParty/")); }
    }

    public RTSend(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = ModuleRules.PCHUsageMode.UseExplicitOrSharedPCHs;

        PublicIncludePaths.AddRange(
            new string[] {
				// ... add public include paths required here ...
                Path.Combine(ModuleDirectory, "../ThirdParty/CudaHistogram/Include")
         }
         );



        PrivateIncludePaths.AddRange(
			new string[] {
				// ... add other private include paths required here ...
			}
			);
			
		
		PublicDependencyModuleNames.AddRange(
			new string[]
			{
				"Core",
                "RHI",
                "RenderCore"
				// ... add other public dependencies that you statically link with here ...
			}
			);
			
		
		PrivateDependencyModuleNames.AddRange(
			new string[]
			{
				"CoreUObject",
				"Engine",
				"Slate",
				"SlateCore",
				// ... add private dependencies that you statically link with here ...	
			}
			);
		
		
		DynamicallyLoadedModuleNames.AddRange(
			new string[]
			{
				// ... add any modules that your module loads dynamically here ...
			}
			);

        if ((Target.Platform == UnrealTargetPlatform.Win64))
        {
            string cudaSDKPath = System.Environment.GetEnvironmentVariable("CUDA_PATH");
            PublicAdditionalLibraries.Add(Path.Combine(ThirdPartyPath, "CudaHistogram/x64/Release", "CudaHistogram.lib"));
            PublicAdditionalLibraries.Add(Path.Combine(cudaSDKPath, "lib/x64", "cudart_static.lib"));
        }
    }
}
