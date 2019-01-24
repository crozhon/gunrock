// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * test_hits.cu
 *
 * @brief Simple test driver program for using HITS algorithm to compute rank.
 */

#include <stdio.h>
#include <string>
#include <deque>
#include <vector>
#include <iostream>
#include <cstdlib>

// Utilities and correctness-checking
#include <gunrock/util/test_utils.cuh>

// Graph construction utils
#include <gunrock/graphio/market.cuh>

// BFS includes
#include <gunrock/app/hits/hits_enactor.cuh>
#include <gunrock/app/hits/hits_problem.cuh>
#include <gunrock/app/hits/hits_functor.cuh>

// Operator includes
#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>

#include <moderngpu.cuh>

using namespace gunrock;
using namespace gunrock::app;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::hits;


/******************************************************************************
 * Defines, constants, globals
 ******************************************************************************/

template <typename VertexId, typename Value>
struct RankPair
{
    VertexId        vertex_id;
    Value           page_rank;

    RankPair(VertexId vertex_id, Value page_rank) :
        vertex_id(vertex_id), page_rank(page_rank) {}
};

template<typename RankPair>
bool HITSCompare(
    RankPair elem1,
    RankPair elem2)
{
    return elem1.page_rank > elem2.page_rank;
}

/******************************************************************************
 * Housekeeping Routines
 ******************************************************************************/
void Usage()
{
    printf(
        "test <graph-type> [graph-type-arguments]\n"
        "Graph type and graph type arguments:\n"
        "    market <matrix-market-file-name>\n"
        "        Reads a Matrix-Market coordinate-formatted graph of\n"
        "        directed/undirected edges from STDIN (or from the\n"
        "        optionally-specified file).\n"
        "    rmat (default: rmat_scale = 10, a = 0.57, b = c = 0.19)\n"
        "        Generate R-MAT graph as input\n"
        "        --rmat_scale=<vertex-scale>\n"
        "        --rmat_nodes=<number-nodes>\n"
        "        --rmat_edgefactor=<edge-factor>\n"
        "        --rmat_edges=<number-edges>\n"
        "        --rmat_a=<factor> --rmat_b=<factor> --rmat_c=<factor>\n"
        "        --rmat_seed=<seed>\n"
        "    rgg (default: rgg_scale = 10, rgg_thfactor = 0.55)\n"
        "        Generate Random Geometry Graph as input\n"
        "        --rgg_scale=<vertex-scale>\n"
        "        --rgg_nodes=<number-nodes>\n"
        "        --rgg_thfactor=<threshold-factor>\n"
        "        --rgg_threshold=<threshold>\n"
        "        --rgg_vmultipiler=<vmultipiler>\n"
        "        --rgg_seed=<seed>\n\n"
        "Optional arguments:\n"
        "[--device=<device_index>] Set GPU(s) for testing (Default: 0).\n"
        "[--instrumented]          Keep kernels statics [Default: Disable].\n"
        "                          total_queued, search_depth and barrier duty.\n"
        "                          (a relative indicator of load imbalance.)\n"
        "[--disable-size-check]    Disable frontier queue size check.\n"
        "[--grid-size=<grid size>] Maximum allowed grid size setting.\n"
        "[--queue-sizing=<factor>] Allocates a frontier queue sized at: \n"
        "                          (graph-edges * <factor>). (Default: 1.0)\n"
        "[--v]                     Print verbose per iteration debug info.\n"
        "[--iteration-num=<num>]   Number of runs to perform the test.\n"
        "[--quiet]                 No output (unless --json is specified).\n"
        "[--json]                  Output JSON-format statistics to STDOUT.\n"
        "[--jsonfile=<name>]       Output JSON-format statistics to file <name>\n"
        "[--jsondir=<dir>]         Output JSON-format statistics to <dir>/name,\n"
        "                          where name is auto-generated.\n"
    );
}

/**
 * @brief Displays the BFS result (i.e., distance from source)
 *
 * @param[in] hrank Pointer to hub rank score array
 * @param[in] arank Pointer to authority rank score array
 * @param[in] nodes Number of nodes in the graph.
 */
template<typename SizeT, typename Value>
void DisplaySolution(Value *hrank, Value *arank, SizeT nodes)
{
    //sort the top page ranks
    RankPair<SizeT, Value> *hr_list =
        (RankPair<SizeT, Value>*)malloc(sizeof(RankPair<SizeT, Value>) * nodes);
    RankPair<SizeT, Value> *ar_list =
        (RankPair<SizeT, Value>*)malloc(sizeof(RankPair<SizeT, Value>) * nodes);

    for (SizeT i = 0; i < nodes; ++i)
    {
        hr_list[i].vertex_id = i;
        hr_list[i].page_rank = hrank[i];
        ar_list[i].vertex_id = i;
        ar_list[i].page_rank = arank[i];
    }
    std::stable_sort(
        hr_list, hr_list + nodes, HITSCompare<RankPair<SizeT, Value> >);
    std::stable_sort(
        ar_list, ar_list + nodes, HITSCompare<RankPair<SizeT, Value> >);

    // Print out at most top 10 largest components
    SizeT top = (nodes < 10) ? nodes : 10;
    printf("Top %lld Ranks:\n", (long long)top);
    for (SizeT i = 0; i < top; ++i)
    {
        printf("Vertex ID: %lld, Hub Rank: %5f\n",
               (long long)hr_list[i].vertex_id, hr_list[i].page_rank);
        printf("Vertex ID: %lld, Authority Rank: %5f\n",
               (long long)ar_list[i].vertex_id, ar_list[i].page_rank);
    }

    free(hr_list);
    free(ar_list);
}

/******************************************************************************
 * BFS Testing Routines
 *****************************************************************************/

/**
 * @brief A simple CPU-based reference HITS implementation.
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 *
 * @param[in] graph Reference to the CSR graph we process on
 * @param[in] inv_graph Reference to the inversed CSR graph we process on
 * @param[in] hrank Host-side vector to store CPU computed hub rank scores for each node
 * @param[in] arank Host-side vector to store CPU computed authority rank scores for each node
 * @param[in] max_iter max iteration to go
 * @param[in] quiet Don't print out anything to stdout
 */
template <
    typename VertexId,
    typename SizeT,
    typename Value>
void ReferenceHITS(
    const Csr<VertexId, SizeT, Value>       &graph,
    const Csr<VertexId, SizeT, Value>       &inv_graph,
    Value                                   *hrank,
    Value                                   *arank,
    SizeT                                   max_iter,
    bool                                    quiet = false)
{
    //
    // Compute HITS rank
    //

    // Note: the inv_graph matrix is a transpose of graph.

    CpuTimer cpu_timer;
    cpu_timer.Start();

    // Initialize all hub and authority scores to 1
    for (SizeT i = 0; i < graph.nodes; i++)
    {
        hrank[i] = 1;
        arank[i] = 1;
    }

    // Iterate so the hub and authority scores converge
    for (SizeT iterCount = 0; iterCount < max_iter; iterCount++)
    {
        // Used to normalize the hub and authority score vectors
        Value norm = 0; 
       
        // Used to track position in the row offset vector
        SizeT idxStart = 0;

        // Iterate through all pages p
        for (SizeT p = 0; p < inv_graph.nodes; p++)
        {
            arank[p] = 0;  // Initialize the current node's authority rank to 0

            // Get the number of sites that connect to the current page
            SizeT numIncomingConnections = inv_graph.row_offsets[p+1] -
                                            inv_graph.row_offsets[p];

            // Get the indices of the incoming connections and update the
            // authority value of the current page
            for (SizeT i = idxStart; i < idxStart+numIncomingConnections; i++)
            {
                arank[p] += hrank[inv_graph.column_indices[i]];
            }

            //norm += pow(arank[p], 2.0);
            norm += pow(arank[p], 1.0);

            idxStart += numIncomingConnections;
        }

        //norm = sqrt(norm);

        // Normalize the authority scores
        for (SizeT page = 0; page < graph.nodes; page++)
        {
            arank[page] = arank[page]/norm;
        }

        // Reset the norm to compute hub scores
        norm = 0.0;

        // Reset offset start index
        idxStart = 0;

        // Similar to the last step, iterate through all pages
        for (SizeT p = 0; p < graph.nodes; p++)
        {
            hrank[p] = 0;

            // Get the number of sites that the current page connects to
            SizeT numOutgoingConnections = graph.row_offsets[p+1] - 
                                            graph.row_offsets[p];

            // Get the indices of the outgoing connections and update the hub
            // value
            for (SizeT i = idxStart; i < idxStart+numOutgoingConnections; i++)
            {
                hrank[p] += arank[graph.column_indices[i]];
            }

            //norm += pow(hrank[p], 2.0);
            norm += pow(hrank[p], 1.0);

            idxStart += numOutgoingConnections;
        }

        //norm = sqrt(norm);

        // Normalize the hub scores
        for (SizeT page = 0; page < graph.nodes; page++)
        {
            hrank[page] = hrank[page]/norm;
        }
    }

    // for (SizeT page = 0; page < graph.nodes; page++)
    // {
    //     printf("arank %d: %5f, hrank %d, %5f\n", page, arank[page], page, hrank[page]);
    // }

    cpu_timer.Stop();
    float elapsed = cpu_timer.ElapsedMillis();

    if (!quiet) { printf("CPU HITS finished in %lf msec.\n", elapsed); }
}

/**
 * @brief RunTests
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 * @tparam DEBUG
 * @tparam SIZE_CHECK
 *
 * @param[in] info Pointer to info contains parameters and statistics.
 */
template <
    typename VertexId,
    typename SizeT,
    typename Value>
    //bool INSTRUMENT,
    //bool DEBUG,
    //bool SIZE_CHECK >
void RunTests(Info<VertexId, SizeT, Value> *info)
{
    typedef HITSProblem < VertexId,
            SizeT,
            Value > Problem;
    typedef HITSEnactor < Problem>
            Enactor;

    Csr<VertexId, SizeT, Value> *csr = info->csr_ptr;
    Csr<VertexId, SizeT, Value> *csc = info->csc_ptr;
    VertexId    src                 = info->info["source_vertex"    ].get_int64();
    int         max_grid_size       = info->info["max_grid_size"    ].get_int  ();
    SizeT       max_iter            = info->info["max_iteration"    ].get_int  ();
    Value       delta               = info->info["delta"            ].get_real ();
    int         num_gpus            = info->info["num_gpus"         ].get_int  ();
    double      max_queue_sizing    = info->info["max_queue_sizing" ].get_real ();
    double      max_queue_sizing1   = info->info["max_queue_sizing1"].get_real ();
    double      max_in_sizing       = info->info["max_in_sizing"    ].get_real ();
    std::string partition_method    = info->info["partition_method" ].get_str  ();
    double      partition_factor    = info->info["partition_factor" ].get_real ();
    int         partition_seed      = info->info["partition_seed"   ].get_int  ();
    bool        quick_mode          = info->info["quick_mode"       ].get_bool ();
    bool        quiet_mode          = info->info["quiet_mode"       ].get_bool ();
    bool        stream_from_host    = info->info["stream_from_host" ].get_bool ();
    bool        instrument          = info->info["instrument"       ].get_bool (); 
    bool        debug               = info->info["debug_mode"       ].get_bool (); 
    bool        size_check          = info->info["size_check"       ].get_bool (); 
    CpuTimer    cpu_timer;

    cpu_timer.Start();
    json_spirit::mArray device_list = info->info["device_list"].get_array();
    int* gpu_idx = new int[num_gpus];
    for (int i = 0; i < num_gpus; i++) gpu_idx[i] = device_list[i].get_int();

    ContextPtr   *context = (ContextPtr*)   info->context;
    cudaStream_t *streams = (cudaStream_t*) info->streams;

    // Allocate host-side array (for both reference and GPU-computed results)
    Value *reference_hrank   = (Value*)malloc(sizeof(Value) * csr->nodes);
    Value *reference_arank   = (Value*)malloc(sizeof(Value) * csr->nodes);
    Value *h_hrank           = (Value*)malloc(sizeof(Value) * csr->nodes);
    Value *h_arank           = (Value*)malloc(sizeof(Value) * csr->nodes);
    Value *reference_check_h = (quick_mode) ? NULL : reference_hrank;
    Value *reference_check_a = (quick_mode) ? NULL : reference_arank;

    // Allocate HITS enactor map

    // Allocate problem on GPU
    Problem *problem = new Problem;
    util::GRError(problem->Init(
        stream_from_host,
        *csr,
        *csc,
        num_gpus,
        gpu_idx,
        partition_method,
        streams,
        max_queue_sizing,
        max_in_sizing,
        partition_factor,
        partition_seed),
        "Problem HITS Initialization Failed", __FILE__, __LINE__);

    Enactor *enactor = new Enactor(
        num_gpus, gpu_idx, instrument, debug, size_check);
    util::GRError(enactor -> Init(
        context, problem, max_grid_size),
        "HITS Enactor Init failed", __FILE__, __LINE__);
    cpu_timer.Stop();
    info -> info["preprocess_time"] = cpu_timer.ElapsedMillis();

    //
    // Compute reference CPU HITS solution for source-distance
    //
    if (reference_check_h != NULL)
    {
        if (!quiet_mode) printf("Computing reference value...\n");
        ReferenceHITS(
            *csr,
            *csc,
            reference_check_h,
            reference_check_a,
            max_iter);
        if (!quiet_mode) printf("\n");

        // Display CPU solution
        if (!quiet_mode) printf("CPU Algorithm Results:\n");
        if (!quiet_mode) DisplaySolution(reference_check_h, reference_check_a, csr->nodes);
        if (!quiet_mode) printf("\n");
    }

    // Perform HITS
    util::GRError(
        problem->Reset(src, delta, enactor -> GetFrontierType()),
        "HITS Problem Data Reset Failed", __FILE__, __LINE__);
    cpu_timer.Start();
    util::GRError(
        enactor -> Enact(max_iter),
        "HITS Problem Enact Failed", __FILE__, __LINE__);
    cpu_timer.Stop();

    double elapsed = cpu_timer.ElapsedMillis();

    cpu_timer.Start();
    // Copy out results
    util::GRError(
        problem->Extract(h_hrank, h_arank),
        "HITS Problem Data Extraction Failed", __FILE__, __LINE__);

    // Display GPU Solution
    if (!quiet_mode) printf("GPU Algorithm Results:\n");
    if (!quiet_mode) DisplaySolution(h_hrank, h_arank, csr->nodes);

    info->ComputeCommonStats(enactor -> enactor_stats.GetPointer(), elapsed, (VertexId*) NULL);

    // Cleanup
    if (problem) delete problem;
    if (enactor) delete enactor;
    if (reference_check_h) free(reference_check_h);
    if (reference_check_a) free(reference_check_a);

    if (h_hrank) free(h_hrank);
    if (h_arank) free(h_arank);

    cudaDeviceSynchronize();
    cpu_timer.Stop();
    info->info["postprocess_time"] = cpu_timer.ElapsedMillis();
}

/******************************************************************************
 * Main
 ******************************************************************************/
template <
    typename VertexId,
    typename SizeT,
    typename Value>
int main_(CommandLineArgs *args)
{
    CpuTimer cpu_timer, cpu_timer2;
    cpu_timer.Start();
    Csr <VertexId, SizeT, Value> csr(false);  // CSR graph we process on
    Csr <VertexId, SizeT, Value> csc(false);  // CSC graph we process on
    Info<VertexId, SizeT, Value> *info = new Info<VertexId, SizeT, Value>;

    info->info["undirected"] = false;
    cpu_timer2.Start();
    info->Init("HITS", *args, csr, csc);
    cpu_timer2.Stop();
    info->info["load_time"] = cpu_timer2.ElapsedMillis();

    // TODO: add a CPU Reference algorithm,
    // before that, quick_mode always on.
    info->info["quick_mode"] = false;
    info->info["max_iteration"] = 1000; // Increased by Jonathan
    RunTests<VertexId, SizeT, Value>(info);
    cpu_timer.Stop();
    info->info["total_time"] = cpu_timer.ElapsedMillis();

    if (!(info->info["quiet_mode"].get_bool()))
    {
        info->DisplayStats();  // display collected statistics
    }

    info->CollectInfo();  // collected all the info and put into JSON mObject
    return 0;
}

template <
    typename VertexId, // the vertex identifier type, usually int or long long
    typename SizeT   > // the size tyep, usually int or long long
int main_Value(CommandLineArgs *args)
{
// disabled to reduce compile time
//    if (args -> CheckCmdLineFlag("64bit-Value"))
//        return main_<VertexId, SizeT, double>(args);
//    else 
        return main_<VertexId, SizeT, float >(args);
}

template <
    typename VertexId>
int main_SizeT(CommandLineArgs *args)
{
// disabled to reduce compile time
//    if (args -> CheckCmdLineFlag("64bit-SizeT"))
//        return main_Value<VertexId, long long>(args);
//    else
        return main_Value<VertexId, int      >(args);
}

int main_VertexId(CommandLineArgs *args)
{
    // disabled, because oprtr::filter::KernelPolicy::SmemStorage is too large for 64bit VertexId
    //if (args -> CheckCmdLineFlag("64bit-VertexId"))
    //    return main_SizeT<long long>(args);
    //else 
        return main_SizeT<int      >(args);
}

int main(int argc, char** argv)
{
    CommandLineArgs args(argc, argv);
    int graph_args = argc - args.ParsedArgc() - 1;
    if (argc < 2 || graph_args < 1 || args.CheckCmdLineFlag("help"))
    {
        Usage();
        return 1;
    }

    return main_VertexId(&args);
}
// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
