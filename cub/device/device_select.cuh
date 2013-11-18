
/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2013, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * cub::DeviceSelect provides device-wide, parallel operations for constructing subsets from data items residing within global memory.
 */

#pragma once

#include <stdio.h>
#include <iterator>

#include "device_scan.cuh"
#include "region/block_select_region.cuh"
#include "../thread/thread_operators.cuh"
#include "../grid/grid_queue.cuh"
#include "../util_debug.cuh"
#include "../util_device.cuh"
#include "../util_vector.cuh"
#include "../util_namespace.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {


/******************************************************************************
 * Kernel entry points
 *****************************************************************************/

#ifndef DOXYGEN_SHOULD_SKIP_THIS    // Do not document


/**
 * Select kernel entry point (multi-block)
 *
 * Performs functor-based selection if SelectOp functor type != NullType
 * Otherwise performs flag-based selection if FlagIterator's value type != NullType
 * Otherwise performs discontinuity selection (keep unique)
 */
template <
    typename    BlockSelectRegionPolicy,        ///< Parameterized BlockSelectRegionPolicy tuning policy type
    typename    InputIterator,                  ///< Random-access input iterator type for selection items
    typename    FlagIterator,                   ///< Random-access input iterator type for selection flags (NullType* if a selection functor or discontinuity flagging is to be used for selection)
    typename    OutputIterator,                 ///< Random-access output iterator type for selected items
    typename    NumSelectedIterator,            ///< Output iterator type for recording number of items selected
    typename    SelectOp,                       ///< Selection operator type (NullType if selection flags or discontinuity flagging is to be used for selection)
    typename    Offset,                         ///< Signed integer type for global offsets
    typename    OffsetTuple>                    ///< Signed integer tuple type for global scatter offsets (selections and rejections)
__launch_bounds__ (int(BlockSelectRegionPolicy::BLOCK_THREADS))
__global__ void SelectRegionKernel(
    InputIterator                       d_in,               ///< [in] Input iterator pointing to data items
    FlagIterator                        d_flags,            ///< [in] Input iterator pointing to selection flags
    OutputIterator                      d_out,              ///< [in] Output iterator pointing to selected items
    NumSelectedIterator                 d_num_selected,     ///< [in] Output iterator pointing to total number selected
    LookbackTileDescriptor<OffsetTuple> *d_tile_status,     ///< [in] Global list of tile status
    SelectOp                            select_op,          ///< [in] Selection operator
    Offset                              num_items,          ///< [in] Total number of items to select from
    int                                 num_tiles,          ///< [in] Total number of tiles for the entire problem
    GridQueue<int>                      queue)              ///< [in] Drain queue descriptor for dynamically mapping tile data onto thread blocks
{
    enum
    {
        TILE_STATUS_PADDING = CUB_PTX_WARP_THREADS,
    };

    // Thread block type for selecting data from input tiles
    typedef BlockSelectRegion<
        BlockSelectRegionPolicy,
        InputIterator,
        FlagIterator,
        OutputIterator,
        NumSelectedIterator,
        SelectOp,
        OffsetTuple> BlockSelectRegionT;

    // Shared memory for BlockSelectRegion
    __shared__ typename BlockSelectRegionT::TempStorage temp_storage;

    // Process tiles
    BlockSelectRegionT(temp_storage, d_in, d_flags, d_out, select_op, num_items).ConsumeRegion(
        num_tiles,
        queue,
        d_tile_status + TILE_STATUS_PADDING,
        d_num_selected);
}




/******************************************************************************
 * Dispatch
 ******************************************************************************/

/**
 * Internal dispatch routine
 */
template <
    typename    InputIterator,                  ///< Random-access input iterator type for selection items
    typename    FlagIterator,                   ///< Random-access input iterator type for selection flags (NullType* if a selection functor or discontinuity flagging is to be used for selection)
    typename    OutputIterator,                 ///< Random-access output iterator type for selected items
    typename    NumSelectedIterator,            ///< Output iterator type for recording number of items selected
    typename    SelectOp,                       ///< Selection operator type (NullType if selection flags or discontinuity flagging is to be used for selection)
    typename    OffsetTuple>                    ///< Signed integer tuple type for global scatter offsets (selections and rejections)
struct DeviceSelectDispatch
{
    /******************************************************************************
     * Types and constants
     ******************************************************************************/

    enum
    {
        TILE_STATUS_PADDING     = 32,
        INIT_KERNEL_THREADS     = 128
    };

    // Data type of input iterator
    typedef typename std::iterator_traits<InputIterator>::value_type T;

    // Data type of flag iterator
    typedef typename std::iterator_traits<FlagIterator>::value_type Flag;

    // Signed integer type for global offsets
    typedef typename OffsetTuple::BaseType Offset;

    // Tile status descriptor type
    typedef LookbackTileDescriptor<OffsetTuple> TileDescriptor;


    /******************************************************************************
     * Tuning policies
     ******************************************************************************/

    /// SM35
    struct Policy350
    {
        enum {
            NOMINAL_4B_ITEMS_PER_THREAD = 8,
            ITEMS_PER_THREAD            = CUB_MIN(NOMINAL_4B_ITEMS_PER_THREAD, CUB_MAX(1, (NOMINAL_4B_ITEMS_PER_THREAD * 4 / sizeof(T)))),
        };

        typedef BlockSelectRegionPolicy<
                128,
                ITEMS_PER_THREAD,
                BLOCK_LOAD_DIRECT,
                false,
                LOAD_LDG,
                false,
                BLOCK_SCAN_RAKING_MEMOIZE>
            SelectRegionPolicy;
    };

    /// SM30
    struct Policy300
    {
        enum {
            NOMINAL_4B_ITEMS_PER_THREAD = 5,
            ITEMS_PER_THREAD            = CUB_MIN(NOMINAL_4B_ITEMS_PER_THREAD, CUB_MAX(1, (NOMINAL_4B_ITEMS_PER_THREAD * 4 / sizeof(T)))),
        };

        typedef BlockSelectRegionPolicy<
                256,
                ITEMS_PER_THREAD,
                BLOCK_LOAD_WARP_TRANSPOSE,
                false,
                LOAD_DEFAULT,
                false,
                BLOCK_SCAN_RAKING_MEMOIZE>
            SelectRegionPolicy;
    };

    /// SM20
    struct Policy200
    {
        enum {
            NOMINAL_4B_ITEMS_PER_THREAD = 9,
            ITEMS_PER_THREAD            = CUB_MIN(NOMINAL_4B_ITEMS_PER_THREAD, CUB_MAX(1, (NOMINAL_4B_ITEMS_PER_THREAD * 4 / sizeof(T)))),
        };

        typedef BlockSelectRegionPolicy<
                128,
                ITEMS_PER_THREAD,
                BLOCK_LOAD_WARP_TRANSPOSE,
                false,
                LOAD_DEFAULT,
                false,
                BLOCK_SCAN_RAKING_MEMOIZE>
            SelectRegionPolicy;
    };

    /// SM13
    struct Policy130
    {
        enum {
            NOMINAL_4B_ITEMS_PER_THREAD = 9,
            ITEMS_PER_THREAD            = CUB_MIN(NOMINAL_4B_ITEMS_PER_THREAD, CUB_MAX(1, (NOMINAL_4B_ITEMS_PER_THREAD * 4 / sizeof(T)))),
        };

        typedef BlockSelectRegionPolicy<
                64,
                ITEMS_PER_THREAD,
                BLOCK_LOAD_WARP_TRANSPOSE,
                true,
                LOAD_DEFAULT,
                false,
                BLOCK_SCAN_RAKING_MEMOIZE>
            SelectRegionPolicy;
    };

    /// SM10
    struct Policy100
    {
        enum {
            NOMINAL_4B_ITEMS_PER_THREAD = 7,
            ITEMS_PER_THREAD            = CUB_MIN(NOMINAL_4B_ITEMS_PER_THREAD, CUB_MAX(1, (NOMINAL_4B_ITEMS_PER_THREAD * 4 / sizeof(T)))),
        };

        typedef BlockSelectRegionPolicy<
                128,
                ITEMS_PER_THREAD,
                BLOCK_LOAD_WARP_TRANSPOSE,
                true,
                LOAD_DEFAULT,
                false,
                BLOCK_SCAN_RAKING>
            SelectRegionPolicy;
    };


    /******************************************************************************
     * Tuning policies of current PTX compiler pass
     ******************************************************************************/

#if (CUB_PTX_VERSION >= 350)
    typedef Policy350 PtxPolicy;

#elif (CUB_PTX_VERSION >= 300)
    typedef Policy300 PtxPolicy;

#elif (CUB_PTX_VERSION >= 200)
    typedef Policy200 PtxPolicy;

#elif (CUB_PTX_VERSION >= 130)
    typedef Policy130 PtxPolicy;

#else
    typedef Policy100 PtxPolicy;

#endif

    // "Opaque" policies (whose parameterizations aren't reflected in the type signature)
    struct PtxSelectRegionPolicy : PtxPolicy::SelectRegionPolicy {};


    /******************************************************************************
     * Utilities
     ******************************************************************************/

    /**
     * Initialize kernel dispatch configurations with the policies corresponding to the PTX assembly we will use
     */
    template <typename KernelConfig>
    __host__ __device__ __forceinline__
    static void InitConfigs(
        int             ptx_version,
        KernelConfig    &select_region_config)
    {
    #ifdef __CUDA_ARCH__

        // We're on the device, so initialize the kernel dispatch configurations with the current PTX policy
        select_region_config.Init<PtxSelectRegionPolicy>();

    #else

        // We're on the host, so lookup and initialize the kernel dispatch configurations with the policies that match the device's PTX version
        if (ptx_version >= 350)
        {
            select_region_config.template Init<typename Policy350::SelectRegionPolicy>();
        }
        else if (ptx_version >= 300)
        {
            select_region_config.template Init<typename Policy300::SelectRegionPolicy>();
        }
        else if (ptx_version >= 200)
        {
            select_region_config.template Init<typename Policy200::SelectRegionPolicy>();
        }
        else if (ptx_version >= 130)
        {
            select_region_config.template Init<typename Policy130::SelectRegionPolicy>();
        }
        else
        {
            select_region_config.template Init<typename Policy100::SelectRegionPolicy>();
        }

    #endif
    }


    /**
     * Kernel kernel dispatch configuration.  Mirrors the constants within BlockSelectRegionPolicy.
     */
    struct KernelConfig
    {
        int                     block_threads;
        int                     items_per_thread;
        BlockLoadAlgorithm      load_policy;
        bool                    two_phase_scatter;
        BlockScanAlgorithm      scan_algorithm;

        template <typename BlockSelectRegionPolicy>
        __host__ __device__ __forceinline__
        void Init()
        {
            block_threads               = BlockSelectRegionPolicy::BLOCK_THREADS;
            items_per_thread            = BlockSelectRegionPolicy::ITEMS_PER_THREAD;
            load_policy                 = BlockSelectRegionPolicy::LOAD_ALGORITHM;
            two_phase_scatter           = BlockSelectRegionPolicy::TWO_PHASE_SCATTER;
            scan_algorithm              = BlockSelectRegionPolicy::SCAN_ALGORITHM;
        }

        __host__ __device__ __forceinline__
        void Print()
        {
            printf("%d, %d, %d, %d, %d",
                block_threads,
                items_per_thread,
                load_policy,
                two_phase_scatter,
                scan_algorithm);
        }
    };


    /******************************************************************************
     * Dispatch entrypoints
     ******************************************************************************/

    /**
     * Internal dispatch routine for computing a device-wide prefix scan using the
     * specified kernel functions.
     */
    template <
        typename                    ScanInitKernelPtr,              ///< Function type of cub::ScanInitKernel
        typename                    SelectRegionKernelPtr>          ///< Function type of cub::SelectRegionKernelPtr
    __host__ __device__ __forceinline__
    static cudaError_t Dispatch(
        void                        *d_temp_storage,                ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is returned in \p temp_storage_bytes and no work is done.
        size_t                      &temp_storage_bytes,            ///< [in,out] Size in bytes of \p d_temp_storage allocation
        InputIterator               d_in,                           ///< [in] Input iterator pointing to data items
        FlagIterator                d_flags,                        ///< [in] Input iterator pointing to selection flags
        OutputIterator              d_out,                          ///< [in] Output iterator pointing to selected items
        NumSelectedIterator         d_num_selected,                 ///< [in] Output iterator pointing to total number selected
        SelectOp                    select_op,                      ///< [in] Selection operator
        Offset                      num_items,                      ///< [in] Total number of items to select from
        cudaStream_t                stream,                         ///< [in] CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                        debug_synchronous,              ///< [in] Whether or not to synchronize the stream after every kernel launch to check for errors.  Also causes launch configurations to be printed to the console.  Default is \p false.
        int                         ptx_version,                    ///< [in] PTX version of dispatch kernels
        int                         sm_version,                     ///< [in] SM version of target device to use when computing SM occupancy
        ScanInitKernelPtr           init_kernel,                    ///< [in] Kernel function pointer to parameterization of cub::ScanInitKernel
        SelectRegionKernelPtr       select_region_kernel,           ///< [in] Kernel function pointer to parameterization of cub::SelectRegionKernelPtr
        KernelConfig                select_region_config)           ///< [in] Dispatch parameters that match the policy that \p select_region_kernel was compiled for
    {

#ifndef CUB_RUNTIME_ENABLED

        // Kernel launch not supported from this device
        return CubDebug(cudaErrorNotSupported);

#else

        cudaError error = cudaSuccess;
        do
        {
            // Number of input tiles
            int tile_size = select_region_config.block_threads * select_region_config.items_per_thread;
            int num_tiles = (num_items + tile_size - 1) / tile_size;

            // Temporary storage allocation requirements
            void* allocations[2];
            size_t allocation_sizes[2] =
            {
                (num_tiles + TILE_STATUS_PADDING) * sizeof(TileDescriptor),  // bytes needed for tile status descriptors
                GridQueue<int>::AllocationSize()                                        // bytes needed for grid queue descriptor
            };

            // Alias the temporary allocations from the single storage blob (or set the necessary size of the blob)
            if (CubDebug(error = AliasTemporaries(d_temp_storage, temp_storage_bytes, allocations, allocation_sizes))) break;
            if (d_temp_storage == NULL)
            {
                // Return if the caller is simply requesting the size of the storage allocation
                return cudaSuccess;
            }

            // Alias the allocation for the global list of tile status
            TileDescriptor *d_tile_status = (TileDescriptor*) allocations[0];

            // Alias the allocation for the grid queue descriptor
            GridQueue<int> queue(allocations[1]);

            // Get device ordinal
            int device_ordinal;
            if (CubDebug(error = cudaGetDevice(&device_ordinal))) break;

            // Get SM count
            int sm_count;
            if (CubDebug(error = cudaDeviceGetAttribute (&sm_count, cudaDevAttrMultiProcessorCount, device_ordinal))) break;

            // Log init_kernel configuration
            int init_grid_size = (num_tiles + INIT_KERNEL_THREADS - 1) / INIT_KERNEL_THREADS;
            if (debug_synchronous) CubLog("Invoking init_kernel<<<%d, %d, 0, %lld>>>()\n", init_grid_size, INIT_KERNEL_THREADS, (long long) stream);

            // Invoke init_kernel to initialize tile descriptors and queue descriptors
            init_kernel<<<init_grid_size, INIT_KERNEL_THREADS, 0, stream>>>(
                queue,
                d_tile_status,
                num_tiles);

            // Sync the stream if specified
            if (debug_synchronous && (CubDebug(error = SyncStream(stream)))) break;

            // Get SM occupancy for select_region_kernel
            int select_region_sm_occupancy;
            if (CubDebug(error = MaxSmOccupancy(
                select_region_sm_occupancy,            // out
                sm_version,
                select_region_kernel,
                select_region_config.block_threads))) break;

            // Get device occupancy for select_region_kernel
            int select_region_occupancy = select_region_sm_occupancy * sm_count;

            // Get grid size for scanning tiles
            int select_grid_size;
            if (ptx_version < 200)
            {
                // We don't have atomics (or don't have fast ones), so just assign one block per tile (limited to 65K tiles)
                select_grid_size = num_tiles;
                if (select_grid_size >= (64 * 1024))
                    return cudaErrorInvalidConfiguration;
            }
            else
            {
                select_grid_size = (num_tiles < select_region_occupancy) ?
                    num_tiles :                         // Not enough to fill the device with threadblocks
                    select_region_occupancy;            // Fill the device with threadblocks
            }

            // Log select_region_kernel configuration
            if (debug_synchronous) CubLog("Invoking select_region_kernel<<<%d, %d, 0, %lld>>>(), %d items per thread, %d SM occupancy\n",
                select_grid_size, select_region_config.block_threads, (long long) stream, select_region_config.items_per_thread, select_region_sm_occupancy);

            // Invoke select_region_kernel
            select_region_kernel<<<select_grid_size, select_region_config.block_threads, 0, stream>>>(
                d_in,
                d_flags,
                d_out,
                d_num_selected,
                d_tile_status,
                select_op,
                num_items,
                num_tiles,
                queue);

            // Sync the stream if specified
            if (debug_synchronous && (CubDebug(error = SyncStream(stream)))) break;
        }
        while (0);

        return error;

#endif  // CUB_RUNTIME_ENABLED
    }


    /**
     * Internal dispatch routine
     */
    __host__ __device__ __forceinline__
    static cudaError_t Dispatch(
        void                        *d_temp_storage,                ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is returned in \p temp_storage_bytes and no work is done.
        size_t                      &temp_storage_bytes,            ///< [in,out] Size in bytes of \p d_temp_storage allocation
        InputIterator               d_in,                           ///< [in] Input iterator pointing to data items
        FlagIterator                d_flags,                        ///< [in] Input iterator pointing to selection flags
        OutputIterator              d_out,                          ///< [in] Output iterator pointing to selected items
        NumSelectedIterator         d_num_selected,                 ///< [in] Output iterator pointing to total number selected
        SelectOp                    select_op,                      ///< [in] Selection operator
        Offset                      num_items,                      ///< [in] Total number of items to select from
        cudaStream_t                stream,                         ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                        debug_synchronous)              ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Also causes launch configurations to be printed to the console.  Default is \p false.
    {
        cudaError error = cudaSuccess;
        do
        {
            // Get PTX version
            int ptx_version;
    #ifndef __CUDA_ARCH__
            if (CubDebug(error = PtxVersion(ptx_version))) break;
    #else
            ptx_version = CUB_PTX_VERSION;
    #endif

            // Get kernel kernel dispatch configurations
            KernelConfig select_region_config;
            InitConfigs(ptx_version, select_region_config);

            // Dispatch
            if (CubDebug(error = Dispatch(
                d_temp_storage,
                temp_storage_bytes,
                d_in,
                d_flags,
                d_out,
                d_num_selected,
                select_op,
                num_items,
                stream,
                debug_synchronous,
                ptx_version,
                ptx_version,            // Use PTX version instead of SM version because, as a statically known quantity, this improves device-side launch dramatically but at the risk of imprecise occupancy calculation for mismatches
                ScanInitKernel<T, Offset>,
                SelectRegionKernel<PtxSelectRegionPolicy, InputIterator, FlagIterator, OutputIterator, NumSelectedIterator, SelectOp, Offset, OffsetTuple>,
                select_region_config))) break;
        }
        while (0);

        return error;
    }
};



#endif // DOXYGEN_SHOULD_SKIP_THIS



/******************************************************************************
 * DeviceSelect
 *****************************************************************************/

/**
 * \brief DeviceSelect provides device-wide, parallel operations for selecting items from sequences of data items residing within global memory. ![](device_select.png)
 * \ingroup DeviceModule
 *
 * \par Overview
 * These operations apply a selection criterion to selectively copy
 * items from a specified input sequence to a corresponding output sequence.
 *
 * \par Usage Considerations
 * \cdp_class{DeviceSelect}
 *
 * \par Performance
 *
 * \image html select_perf.png
 *
 */
struct DeviceSelect
{
    /**
     * \brief Uses the sequence of validity flags \p d_flags as a criterion for selectively copying the corresponding items from \p d_in into \p d_out.  The total number of items selected is written to \p d_num_selected.
     *
     * \devicestorage
     *
     * \cdp
     *
     * \iterator
     *
     * \tparam InputIterator        <b>[inferred]</b> Random-access input iterator type for selection items (may be a simple pointer type)
     * \tparam FlagIterator         <b>[inferred]</b> Random-access input iterator type for selection flags (may be a simple pointer type)
     * \tparam OutputIterator       <b>[inferred]</b> Random-access output iterator type for selected items (may be a simple pointer type)
     * \tparam NumSelectedIterator  <b>[inferred]</b> Output iterator type for recording number of items selected (may be a simple pointer type)
     */
    template <
        typename                    InputIterator,
        typename                    FlagIterator,
        typename                    OutputIterator,
        typename                    NumSelectedIterator>
    __host__ __device__ __forceinline__
    static cudaError_t CopyIf(
        void                        *d_temp_storage,                ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is returned in \p temp_storage_bytes and no work is done.
        size_t                      &temp_storage_bytes,            ///< [in,out] Size in bytes of \p d_temp_storage allocation
        InputIterator               d_in,                           ///< [in] Input iterator pointing to data items
        FlagIterator                d_flags,                        ///< [in] Input iterator pointing to selection flags
        OutputIterator              d_out,                          ///< [in] Output iterator pointing to selected items
        NumSelectedIterator         d_num_selected,                 ///< [in] Output iterator pointing to total number selected
        int                         num_items,                      ///< [in] Total number of items to select from
        cudaStream_t                stream             = 0,         ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                        debug_synchronous  = false)     ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  May cause significant slowdown.  Default is \p false.
    {
        // Signed integer type for global offsets
        typedef int Offset;

        // Selection operator
        typedef NullType SelectOp;

        // Offset tuple type
        typedef CubVector<Offset, 1> OffsetTuple;

        return DeviceSelectDispatch<InputIterator, FlagIterator, NumSelectedIterator, OutputIterator, SelectOp, OffsetTuple>::Dispatch(
            d_temp_storage,
            temp_storage_bytes,
            d_in,
            d_flags,
            d_out,
            d_num_selected,
            SelectOp(),
            num_items,
            stream,
            debug_synchronous);
    }


    /**
     * \brief Uses the \p select_op operator as a criterion for selectively copying items from \p d_in into \p d_out.  The total number of items selected is written to \p d_num_selected.
     *
     * \devicestorage
     *
     * \cdp
     *
     * \iterator
     *
     * \tparam InputIterator        <b>[inferred]</b> Random-access input iterator type for selection items (may be a simple pointer type)
     * \tparam OutputIterator       <b>[inferred]</b> Random-access output iterator type for selected items (may be a simple pointer type)
     * \tparam NumSelectedIterator  <b>[inferred]</b> Output iterator type for recording number of items selected (may be a simple pointer type)
     * \tparam SelectOp             <b>[inferred]</b> Selection operator type having member <tt>bool operator()(const T &a)</tt>
     */
    template <
        typename                    InputIterator,
        typename                    OutputIterator,
        typename                    NumSelectedIterator,
        typename                    SelectOp>
    __host__ __device__ __forceinline__
    static cudaError_t CopyIf(
        void                        *d_temp_storage,                ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is returned in \p temp_storage_bytes and no work is done.
        size_t                      &temp_storage_bytes,            ///< [in,out] Size in bytes of \p d_temp_storage allocation
        InputIterator               d_in,                           ///< [in] Input iterator pointing to data items
        OutputIterator              d_out,                          ///< [in] Output iterator pointing to selected items
        NumSelectedIterator         d_num_selected,                 ///< [in] Output iterator pointing to total number selected
        int                         num_items,                      ///< [in] Total number of items to select from
        SelectOp                    select_op,                      ///< [in] Unary selection operator
        cudaStream_t                stream             = 0,         ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                        debug_synchronous  = false)     ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  May cause significant slowdown.  Default is \p false.
    {
        // Signed integer type for global offsets
        typedef int Offset;

        // Flag iterator type
        typedef NullType FlagIterator;

        // Offset tuple type
        typedef CubVector<Offset, 1> OffsetTuple;

        return DeviceSelectDispatch<InputIterator, FlagIterator, NumSelectedIterator, OutputIterator, SelectOp, OffsetTuple>::Dispatch(
            d_temp_storage,
            temp_storage_bytes,
            d_in,
            NULL,
            d_out,
            d_num_selected,
            select_op,
            num_items,
            stream,
            debug_synchronous);
    }


    /**
     * \brief Given an input sequence \p d_in having groups of consecutive equal-valued keys, only the first key from each group is selectively copied to \p d_out.  The total number of items selected is written to \p d_num_selected.
     *
     * \devicestorage
     *
     * \cdp
     *
     * \iterator
     *
     * \tparam InputIterator        <b>[inferred]</b> Random-access input iterator type for selection items (may be a simple pointer type)
     * \tparam OutputIterator       <b>[inferred]</b> Random-access output iterator type for selected items (may be a simple pointer type)
     * \tparam NumSelectedIterator  <b>[inferred]</b> Output iterator type for recording number of items selected (may be a simple pointer type)
     */
    template <
        typename                    InputIterator,
        typename                    OutputIterator,
        typename                    NumSelectedIterator>
    __host__ __device__ __forceinline__
    static cudaError_t Unique(
        void                        *d_temp_storage,                ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is returned in \p temp_storage_bytes and no work is done.
        size_t                      &temp_storage_bytes,            ///< [in,out] Size in bytes of \p d_temp_storage allocation
        InputIterator               d_in,                           ///< [in] Input iterator pointing to data items
        OutputIterator              d_out,                          ///< [in] Output iterator pointing to selected items
        NumSelectedIterator         d_num_selected,                 ///< [in] Output iterator pointing to total number selected
        int                         num_items,                      ///< [in] Total number of items to select from
        cudaStream_t                stream             = 0,         ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                        debug_synchronous  = false)     ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  May cause significant slowdown.  Default is \p false.
    {
        // Signed integer type for global offsets
        typedef int Offset;

        // Flag iterator type
        typedef NullType FlagIterator;

        // Selection operator
        typedef NullType SelectOp;

        // Offset tuple type
        typedef CubVector<Offset, 1> OffsetTuple;

        return DeviceSelectDispatch<InputIterator, FlagIterator, NumSelectedIterator, OutputIterator, SelectOp, OffsetTuple>::Dispatch(
            d_temp_storage,
            temp_storage_bytes,
            d_in,
            NULL,
            d_out,
            d_num_selected,
            SelectOp(),
            num_items,
            stream,
            debug_synchronous);
    }


};

}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)


