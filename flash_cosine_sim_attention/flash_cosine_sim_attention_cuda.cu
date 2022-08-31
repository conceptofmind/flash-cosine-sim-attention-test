#include <cuda.h>
#include <cuda_runtime.h>
#include <torch/extension.h>
#include <c10/cuda/CUDAGuard.h>

// constants

__constant__ float EPS = 1e-10;

// type alias

template <typename scalar_t, int dims>
using PackedAccessor = torch::PackedTensorAccessor32<scalar_t, dims, torch::RestrictPtrTraits>;

// forward kernel

template <typename scalar_t>
__global__ void forward_kernel(
    const PackedAccessor<scalar_t, 4> q,
    const PackedAccessor<scalar_t, 4> k,
    const PackedAccessor<scalar_t, 4> v,
    const PackedAccessor<bool, 2> mask,
          PackedAccessor<scalar_t, 4> o,
          PackedAccessor<scalar_t, 3> l,
    const float scale,
    const bool causal,
    const int q_block_size,
    const int k_block_size
) {
    const int batch_idx = blockIdx.x;
    const int head_idx = blockIdx.y;

    const int q_seq_len = q.size(2);
    const int k_seq_len = k.size(2);
    const int k_dim = k.size(3);
    const int v_dim = v.size(3);

    const int num_col_tiles = (k_seq_len + k_block_size - 1) / k_block_size;
    const int num_row_tiles = (q_seq_len + q_block_size - 1) / q_block_size;

    const int row_tile_idx = threadIdx.x;
    const int col_tile_idx = threadIdx.y;

    auto q_ = q[batch_idx][head_idx];
    auto k_ = k[batch_idx][head_idx];
    auto v_ = v[batch_idx][head_idx];
    auto o_ = o[batch_idx][head_idx];
    auto l_ = l[batch_idx][head_idx];
    auto mask_ = mask[batch_idx];

    // shared memory

    extern __shared__ float _shared_mem[];

    float* sm_q_block = (float*) &_shared_mem;
    float* sm_k_block = (float*) &sm_q_block[q_block_size * k_dim];
    float* sm_v_block = (float*) &sm_k_block[k_block_size * k_dim];
    float* sm_l_block = (float*) &sm_v_block[k_block_size * v_dim];
    float* sm_o_block = (float*) &sm_l_block[q_block_size];

    // some variable

    int col_tiles_offset, row_tiles_offset;
    int global_col, global_row;
    bool should_calculate_attn, should_calculate_row, should_calculate_col;

    // loop

    for (int i = 0; i < num_col_tiles; i++) {
        col_tiles_offset = i * k_block_size;
        global_col = col_tiles_offset + col_tile_idx;
        should_calculate_col = global_col < k_seq_len;

        if (row_tile_idx == 0 && should_calculate_col) {
            for (int d = 0; d < k_dim; d++) {
                sm_k_block[(col_tile_idx * k_dim) + d] = k_[global_col][d];
            }

            for (int d = 0; d < v_dim; d++) {
                sm_v_block[(col_tile_idx * v_dim) + d] = v_[global_col][d];
            }
        }

        for (int j = 0; j < num_row_tiles; j++) {
            row_tiles_offset = j * q_block_size;
            global_row = row_tiles_offset + row_tile_idx;
            should_calculate_row = global_row < q_seq_len;

            should_calculate_attn = should_calculate_row && should_calculate_col && (!causal || (causal && (global_row <= (global_col + k_seq_len - q_seq_len))));

            if (col_tile_idx == 0 && should_calculate_row) {
                for (int d = 0; d < k_dim; d++) {
                    sm_q_block[(row_tile_idx * k_dim) + d] = q_[global_row][d];
                }

                sm_l_block[row_tile_idx] = 0.;

                for (int d = 0; d < v_dim; d++) {
                    sm_o_block[(row_tile_idx * v_dim) + d] = 0.;
                }
            }

            __syncthreads();

            if (should_calculate_attn) {
                float tmp = 0;
                for (int d = 0; d < k_dim; d++) {
                    tmp += sm_q_block[(row_tile_idx * k_dim) + d] * sm_k_block[(col_tile_idx * k_dim) + d];
                }

                tmp *= scale;
                tmp -= scale;
                tmp = __expf(tmp);

                atomicAdd(&sm_l_block[row_tile_idx], tmp);

                float exp_weighted_value;

                for (int d = 0; d < v_dim; d++) {
                    exp_weighted_value = tmp * sm_v_block[(col_tile_idx * v_dim) + d];
                    atomicAdd(&sm_o_block[(row_tile_idx * v_dim) + d], exp_weighted_value);
                }
            }

            __syncthreads();

            float tmp_row_sum;

            if (col_tile_idx == 0 && should_calculate_row) {
                tmp_row_sum = sm_l_block[row_tile_idx];

                l_[global_row] = tmp_row_sum;

                for (int d = 0; d < v_dim; d++) {
                    o_[global_row][d] = sm_o_block[(row_tile_idx * v_dim) + d];
                }
            }

            __syncthreads();
        }
    }
}

 // backward kernel

template <typename scalar_t>
__global__ void backward_kernel(
    const PackedAccessor<scalar_t, 4> q,
    const PackedAccessor<scalar_t, 4> k,
    const PackedAccessor<scalar_t, 4> v,
    const PackedAccessor<bool, 2> mask,
          PackedAccessor<scalar_t, 4> dq,
          PackedAccessor<scalar_t, 4> dk,
          PackedAccessor<scalar_t, 4> dv,
    const PackedAccessor<scalar_t, 4> grad_o,
    const PackedAccessor<scalar_t, 4> o,
    const PackedAccessor<scalar_t, 3> l,
    const float scale,
    const bool causal,
    const int q_block_size,
    const int k_block_size
) {
    const int batch_idx = blockIdx.x;
    const int head_idx = blockIdx.y;

    const int q_seq_len = q.size(2);
    const int k_seq_len = k.size(2);
    const int k_dim = k.size(3);
    const int v_dim = v.size(3);

    const int num_col_tiles = (k_seq_len + k_block_size - 1) / k_block_size;
    const int num_row_tiles = (q_seq_len + q_block_size - 1) / q_block_size;

    const int row_tile_idx = threadIdx.x;
    const int col_tile_idx = threadIdx.y;

    auto q_ = q[batch_idx][head_idx];
    auto k_ = k[batch_idx][head_idx];
    auto v_ = v[batch_idx][head_idx];
    auto dq_ = dq[batch_idx][head_idx];
    auto dk_ = dk[batch_idx][head_idx];
    auto dv_ = dv[batch_idx][head_idx];
    auto o_ = o[batch_idx][head_idx];
    auto l_ = l[batch_idx][head_idx];
    auto grad_o_ = grad_o[batch_idx][head_idx];
    auto mask_ = mask[batch_idx];

    // some variables

    int col_tiles_offset, row_tiles_offset;
    bool is_last_col_tile;

    // shared memory

    extern __shared__ float _shared_mem[];

    float* sm_q_block = (float*) &_shared_mem;
    float* sm_k_block = (float*) &sm_q_block[q_block_size * k_dim];
    float* sm_v_block = (float*) &sm_k_block[k_block_size * k_dim];
    float* sm_l_block = (float*) &sm_v_block[k_block_size * v_dim];
    float* sm_o_block = (float*) &sm_l_block[q_block_size];

    // loop

    for (int i = 0; i < num_col_tiles; i++) {
        col_tiles_offset = i * k_block_size;

        if (row_tile_idx == 0) {
            for (int d = 0; d < k_dim; d++) {
                sm_k_block[col_tiles_offset + (col_tile_idx * k_dim) + d] = k_[col_tiles_offset + col_tile_idx][d];
            }

            for (int d = 0; d < v_dim; d++) {
                sm_v_block[col_tiles_offset + (col_tile_idx * v_dim) + d] = v_[col_tiles_offset + col_tile_idx][d];
            }
        }

        for (int j = 0; j < num_row_tiles; j++) {
            is_last_col_tile = (i == (num_col_tiles - 1));
            row_tiles_offset = j * q_block_size;

            if (col_tile_idx == 0) {
                for (int d = 0; d < k_dim; d++) {
                    sm_q_block[row_tiles_offset + (row_tile_idx * k_dim) + d] = q_[row_tiles_offset + row_tile_idx][d];
                }
            }

            __syncthreads();

            float tmp = 0;
            for (int d = 0; d < k_dim; d++) {
                tmp += sm_q_block[(row_tile_idx * k_dim) + d] * sm_k_block[(col_tile_idx * k_dim) + d];
            }

            tmp *= scale;
            tmp -= scale;
            tmp = __expf(tmp);

            __syncthreads();
        }
    }
}

// main c++ function

std::vector<torch::Tensor> flash_cosine_sim_attention_forward(
    torch::Tensor q,
    torch::Tensor k,
    torch::Tensor v,
    torch::Tensor o,
    torch::Tensor l,
    torch::Tensor mask,
    float scale,
    bool causal,
    int q_block_size,
    int k_block_size
) {
    const at::cuda::OptionalCUDAGuard device_guard(device_of(o));

    const int batch = q.size(0);
    const int heads = q.size(1);
    const int k_dim = k.size(3);
    const int v_dim = v.size(3);

    const dim3 threads_per_block(q_block_size, k_block_size);
    const dim3 blocks(batch, heads);
    const unsigned shared_mem_size = ((q_block_size + k_block_size) * k_dim + k_block_size * v_dim + q_block_size + q_block_size * v_dim) * sizeof(float);

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(q.scalar_type(), "forward_cosine_sim_attention_forward", ([&] {
        forward_kernel<scalar_t><<<blocks, threads_per_block, shared_mem_size>>>(
            q.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            k.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            v.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            mask.packed_accessor32<bool, 2, torch::RestrictPtrTraits>(),
            o.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            l.packed_accessor32<scalar_t, 3, torch::RestrictPtrTraits>(),
            scale,
            causal,
            q_block_size,
            k_block_size
        );
    }));

    cudaDeviceSynchronize();

    // handle error

    cudaError_t error = cudaGetLastError();

    if(error != cudaSuccess) {
        printf("CUDA error: %s\n", cudaGetErrorString(error));
        exit(-1);
    }

    // output

    return {o, l};
}

std::vector<torch::Tensor> flash_cosine_sim_attention_backward(
    torch::Tensor grad_o,
    torch::Tensor o,
    torch::Tensor l,
    torch::Tensor q,
    torch::Tensor k,
    torch::Tensor v,
    torch::Tensor mask,
    float scale,
    bool causal,
    int q_block_size,
    int k_block_size
) {
    auto dq = torch::zeros_like(q);
    auto dk = torch::zeros_like(k);
    auto dv = torch::zeros_like(v);

    const at::cuda::OptionalCUDAGuard device_guard(device_of(dq));

    const int batch = dq.size(0);
    const int heads = dq.size(1);
    const int k_dim = k.size(3);
    const int v_dim = v.size(3);

    const dim3 threads_per_block(q_block_size, k_block_size);
    const dim3 blocks(batch, heads);
    const unsigned shared_mem_size = ((q_block_size + k_block_size) * k_dim + k_block_size * v_dim + q_block_size + q_block_size * v_dim) * sizeof(float);

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(q.scalar_type(), "forward_cosine_sim_attention_backward", ([&] {
        backward_kernel<scalar_t><<<blocks, threads_per_block, shared_mem_size>>>(
            q.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            k.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            v.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            mask.packed_accessor32<bool, 2, torch::RestrictPtrTraits>(),
            dq.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            dk.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            dv.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            grad_o.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            o.packed_accessor32<scalar_t, 4, torch::RestrictPtrTraits>(),
            l.packed_accessor32<scalar_t, 3, torch::RestrictPtrTraits>(),
            scale,
            causal,
            q_block_size,
            k_block_size
        );
    }));

    cudaDeviceSynchronize();

    // handle error

    cudaError_t error = cudaGetLastError();

    if(error != cudaSuccess) {
        printf("CUDA error: %s\n", cudaGetErrorString(error));
        exit(-1);
    }

    // output

    return {dq, dk, dv};
}

// bind

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
    m.def("forward", &flash_cosine_sim_attention_forward, "Flash Cosine-Sim Attention Forward");
    m.def("backward", &flash_cosine_sim_attention_backward, "Flash Cosine-Sim Attention Backward");
}
