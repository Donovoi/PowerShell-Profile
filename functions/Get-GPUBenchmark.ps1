function Get-GPUBenchmark {
    param (
        [Parameter(Mandatory = $true)]
        [int]$BenchmarkTimeInSeconds
    )

    Add-Type -AssemblyName System.Runtime.Intrinsics
    Add-type -AssemblyName System.Runtime.Intrinsics.X86


    # Define the benchmark kernel using SIMD and intrinsics
    $benchmarkKernel = @'
    using System;
    using System.Runtime.Intrinsics;
    using System.Runtime.Intrinsics.X86;

    public class GPUBenchmark
    {
        public static double RunBenchmark(int benchmarkTimeInSeconds)
        {
            DateTime startTime = DateTime.Now;
            DateTime endTime = startTime.AddSeconds(benchmarkTimeInSeconds);
            int count = 0;

            while (DateTime.Now < endTime)
            {
                Vector128<int> vector1 = Vector128<int>.Zero;
                Vector128<int> vector2 = Vector128<int>.Zero;
                Vector128<int> result = Sse2.Add(vector1, vector2);
                count++;
            }

            return count / benchmarkTimeInSeconds;
        }
    }
'@

    # Add the required assembly and compile the benchmark kernel
    try {
        $null = Add-Type -TypeDefinition $benchmarkKernel -Language CSharp -ErrorAction Stop
    }
    catch {
        Write-Log -Message "Failed to compile the benchmark kernel. Error: $_"
        return
    }

    # Call the GPU benchmark function
    try {
        $benchmarkResult = [GPUBenchmark]::RunBenchmark($BenchmarkTimeInSeconds)
        Write-Log -Message "GPU Benchmark Score: $benchmarkResult"
    }
    catch {
        Write-Log -Message "Failed to run the GPU benchmark. Error: $_"
    }
}