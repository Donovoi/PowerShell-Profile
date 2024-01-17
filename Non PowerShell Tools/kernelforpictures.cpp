#include <cuda_runtime.h>
#include <iostream>

__global__ void processImageKernel(unsigned char *input, unsigned char *output,
                                   int width, int height) {
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;

  if (x < width && y < height) {
    output[3 * (y * width + x) + 0] = input[3 * (y * width + x) + 0];
    output[3 * (y * width + x) + 1] = input[3 * (y * width + x) + 1];
    output[3 * (y * width + x) + 2] = input[3 * (y * width + x) + 2];
  }
}

extern "C" void processImage(unsigned char *input, unsigned char *output,
                             int width, int height) {
  unsigned char *d_input, *d_output;
  cudaMalloc(&d_input, width * height * 3);
  cudaMalloc(&d_output, width * height * 3);

  cudaMemcpy(d_input, input, width * height * 3, cudaMemcpyHostToDevice);

  dim3 dimBlock(16, 16);
  dim3 dimGrid((width + dimBlock.x - 1) / dimBlock.x,
               (height + dimBlock.y - 1) / dimBlock.y);
  processImageKernel<<<dimGrid, dimBlock>>>(d_input, d_output, width, height);

  cudaMemcpy(output, d_output, width * height * 3, cudaMemcpyDeviceToHost);

  cudaFree(d_input);
  cudaFree(d_output);
}
