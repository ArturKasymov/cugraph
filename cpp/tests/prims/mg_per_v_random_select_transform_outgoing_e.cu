/*
 * Copyright (c) 2021-2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "property_generator.cuh"

#include <utilities/base_fixture.hpp>
#include <utilities/device_comm_wrapper.hpp>
#include <utilities/mg_utilities.hpp>
#include <utilities/test_graphs.hpp>
#include <utilities/test_utilities.hpp>
#include <utilities/thrust_wrapper.hpp>

#include <prims/per_v_random_select_transform_outgoing_e.cuh>
#include <prims/vertex_frontier.cuh>

#include <cugraph/edge_src_dst_property.hpp>
#include <cugraph/graph_functions.hpp>
#include <cugraph/graph_view.hpp>
#include <cugraph/utilities/dataframe_buffer.hpp>
#include <cugraph/utilities/high_res_timer.hpp>
#include <cugraph/utilities/host_scalar_comm.hpp>
#include <cugraph/utilities/thrust_tuple_utils.hpp>
#if 1  // for random seed selection
#include <cugraph/utilities/shuffle_comm.cuh>
#endif

#include <raft/comms/comms.hpp>
#include <raft/comms/mpi_comms.hpp>
#include <raft/core/comms.hpp>
#include <raft/core/handle.hpp>
#include <rmm/device_uvector.hpp>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/tuple.h>
#if 1  // for random seed selection
#include <thrust/random.h>
#include <thrust/shuffle.h>
#endif

#include <gtest/gtest.h>

#include <random>

template <typename vertex_t, typename property_t>
struct e_op_t {
  using result_t = decltype(cugraph::thrust_tuple_cat(thrust::tuple<vertex_t, vertex_t>{},
                                                      cugraph::to_thrust_tuple(property_t{}),
                                                      cugraph::to_thrust_tuple(property_t{})));

  __device__ result_t operator()(
    vertex_t src, vertex_t dst, property_t src_prop, property_t dst_prop, thrust::nullopt_t) const
  {
    if constexpr (cugraph::is_thrust_tuple_of_arithmetic<property_t>::value) {
      static_assert(thrust::tuple_size<property_t>::value == size_t{2});
      return thrust::make_tuple(src,
                                dst,
                                thrust::get<0>(src_prop),
                                thrust::get<1>(src_prop),
                                thrust::get<0>(dst_prop),
                                thrust::get<1>(dst_prop));
    } else {
      return thrust::make_tuple(src, dst, src_prop, dst_prop);
    }
  }
};

struct Prims_Usecase {
  size_t num_seeds{0};
  size_t K{0};
  bool with_replacement{false};
  bool use_invalid_value{false};
  bool test_weighted{false};
  bool check_correctness{true};
};

template <typename input_usecase_t>
class Tests_MGPerVRandomSelectTransformOutgoingE
  : public ::testing::TestWithParam<std::tuple<Prims_Usecase, input_usecase_t>> {
 public:
  Tests_MGPerVRandomSelectTransformOutgoingE() {}

  static void SetUpTestCase() { handle_ = cugraph::test::initialize_mg_handle(); }

  static void TearDownTestCase() { handle_.reset(); }

  virtual void SetUp() {}
  virtual void TearDown() {}

  // Verify the results of per_v_random_select_transform_outgoing_e primitive
  template <typename vertex_t, typename edge_t, typename weight_t, typename property_t>
  void run_current_test(Prims_Usecase const& prims_usecase, input_usecase_t const& input_usecase)
  {
    HighResTimer hr_timer{};

    auto const comm_rank = handle_->get_comms().get_rank();
    auto const comm_size = handle_->get_comms().get_size();

    // 1. create MG graph

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle_->get_comms().barrier();
      hr_timer.start("MG Construct graph");
    }

    cugraph::graph_t<vertex_t, edge_t, false, true> mg_graph(*handle_);
    std::optional<rmm::device_uvector<vertex_t>> d_mg_renumber_map_labels{std::nullopt};
    std::tie(mg_graph, std::ignore, d_mg_renumber_map_labels) =
      cugraph::test::construct_graph<vertex_t, edge_t, weight_t, false, true>(
        *handle_, input_usecase, prims_usecase.test_weighted, true);

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle_->get_comms().barrier();
      hr_timer.stop();
      hr_timer.display_and_clear(std::cout);
    }

    auto mg_graph_view = mg_graph.view();

    // 2. run MG per_v_random_select_transform_outgoing_e primitive

    const int hash_bin_count = 5;

    auto mg_vertex_prop = cugraph::test::generate<vertex_t, property_t>::vertex_property(
      *handle_, *d_mg_renumber_map_labels, hash_bin_count);
    auto mg_src_prop = cugraph::test::generate<vertex_t, property_t>::src_property(
      *handle_, mg_graph_view, mg_vertex_prop);
    auto mg_dst_prop = cugraph::test::generate<vertex_t, property_t>::dst_property(
      *handle_, mg_graph_view, mg_vertex_prop);

    raft::random::RngState rng_state(static_cast<uint64_t>(handle_->get_comms().get_rank()));

    auto mg_vertex_buffer = cugraph::select_random_vertices(
      *handle_, mg_graph_view, rng_state, prims_usecase.num_seeds, false, false);

    constexpr size_t bucket_idx_cur = 0;
    constexpr size_t num_buckets    = 1;

    cugraph::vertex_frontier_t<vertex_t, void, true, false> mg_vertex_frontier(*handle_,
                                                                               num_buckets);
    mg_vertex_frontier.bucket(bucket_idx_cur)
      .insert(cugraph::get_dataframe_buffer_begin(mg_vertex_buffer),
              cugraph::get_dataframe_buffer_end(mg_vertex_buffer));

    using result_t = decltype(cugraph::thrust_tuple_cat(thrust::tuple<vertex_t, vertex_t>{},
                                                        cugraph::to_thrust_tuple(property_t{}),
                                                        cugraph::to_thrust_tuple(property_t{})));

    std::optional<result_t> invalid_value{std::nullopt};
    if (prims_usecase.use_invalid_value) {
      invalid_value                  = result_t{};
      thrust::get<0>(*invalid_value) = cugraph::invalid_vertex_id<vertex_t>::value;
      thrust::get<1>(*invalid_value) = cugraph::invalid_vertex_id<vertex_t>::value;
    }

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle_->get_comms().barrier();
      hr_timer.start("MG per_v_random_select_transform_outgoing_e");
    }

    auto [sample_offsets, sample_e_op_results] =
      cugraph::per_v_random_select_transform_outgoing_e(*handle_,
                                                        mg_graph_view,
                                                        mg_vertex_frontier.bucket(bucket_idx_cur),
                                                        mg_src_prop.view(),
                                                        mg_dst_prop.view(),
                                                        cugraph::edge_dummy_property_t{}.view(),
                                                        e_op_t<vertex_t, property_t>{},
                                                        rng_state,
                                                        prims_usecase.K,
                                                        prims_usecase.with_replacement,
                                                        invalid_value);

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle_->get_comms().barrier();
      hr_timer.stop();
      hr_timer.display_and_clear(std::cout);
    }

    // 3. validate MG results

    if (prims_usecase.check_correctness) {
      cugraph::unrenumber_int_vertices<vertex_t, true>(
        *handle_,
        std::get<0>(sample_e_op_results).data(),
        std::get<0>(sample_e_op_results).size(),
        (*d_mg_renumber_map_labels).data(),
        mg_graph_view.vertex_partition_range_lasts());
      cugraph::unrenumber_int_vertices<vertex_t, true>(
        *handle_,
        std::get<1>(sample_e_op_results).data(),
        std::get<1>(sample_e_op_results).size(),
        (*d_mg_renumber_map_labels).data(),
        mg_graph_view.vertex_partition_range_lasts());
      auto out_degrees = mg_graph_view.compute_out_degrees(*handle_);

      cugraph::graph_t<vertex_t, edge_t, false, false> unrenumbered_graph(*handle_);
      std::tie(unrenumbered_graph, std::ignore, std::ignore) =
        cugraph::test::construct_graph<vertex_t, edge_t, weight_t, false, false>(
          *handle_, input_usecase, prims_usecase.test_weighted, false);
      auto unrenumbered_graph_view = unrenumbered_graph.view();

      rmm::device_uvector<edge_t> unrenumbered_offsets(
        unrenumbered_graph_view.number_of_vertices() + vertex_t{1}, handle_->get_stream());
      thrust::copy(handle_->get_thrust_policy(),
                   unrenumbered_graph_view.local_edge_partition_view().offsets().begin(),
                   unrenumbered_graph_view.local_edge_partition_view().offsets().end(),
                   unrenumbered_offsets.begin());
      rmm::device_uvector<vertex_t> unrenumbered_indices(unrenumbered_graph_view.number_of_edges(),
                                                         handle_->get_stream());
      thrust::copy(handle_->get_thrust_policy(),
                   unrenumbered_graph_view.local_edge_partition_view().indices().begin(),
                   unrenumbered_graph_view.local_edge_partition_view().indices().end(),
                   unrenumbered_indices.begin());

      auto num_invalids = static_cast<size_t>(thrust::count_if(
        handle_->get_thrust_policy(),
        thrust::make_counting_iterator(size_t{0}),
        thrust::make_counting_iterator(mg_vertex_frontier.bucket(bucket_idx_cur).size()),
        [frontier_vertex_first  = mg_vertex_frontier.bucket(bucket_idx_cur).begin(),
         v_first                = mg_graph_view.local_vertex_partition_range_first(),
         sample_offsets         = sample_offsets
                                    ? thrust::make_optional<size_t const*>((*sample_offsets).data())
                                    : thrust::nullopt,
         sample_e_op_results    = cugraph::get_dataframe_buffer_begin(sample_e_op_results),
         out_degrees            = out_degrees.begin(),
         mg_renumber_map_labels = (*d_mg_renumber_map_labels).begin(),
         unrenumbered_offsets   = unrenumbered_offsets.begin(),
         unrenumbered_indices   = unrenumbered_indices.begin(),
         K                      = prims_usecase.K,
         with_replacement       = prims_usecase.with_replacement,
         invalid_value =
           invalid_value ? thrust::make_optional<result_t>(*invalid_value) : thrust::nullopt,
         property_transform = cugraph::test::detail::property_transform<vertex_t, property_t>{
           hash_bin_count}] __device__(size_t i) {
          auto v = *(frontier_vertex_first + i);

          // check sample_offsets

          auto offset_first = sample_offsets ? *(*sample_offsets + i) : K * i;
          auto offset_last  = sample_offsets ? *(*sample_offsets + (i + 1)) : K * (i + 1);
          if (!sample_offsets) {
            size_t num_valids{0};
            for (size_t j = offset_first; j < offset_last; ++j) {
              auto e_op_result = *(sample_e_op_results + j);
              if (e_op_result == *invalid_value) { break; }
              ++num_valids;
            }
            for (size_t j = offset_first + num_valids; j < offset_last; ++j) {
              auto e_op_result = *(sample_e_op_results + j);
              if (e_op_result != *invalid_value) { return true; }
            }
            offset_last = offset_first + num_valids;
          }
          auto count = offset_last - offset_first;

          auto v_offset   = v - v_first;
          auto out_degree = *(out_degrees + v_offset);
          if (with_replacement) {
            if ((out_degree > 0 && count != K) || (out_degree == 0 && count != 0)) { return true; }
          } else {
            if (count != std::min(static_cast<size_t>(out_degree), K)) { return true; }
          }

          // check sample_e_op_results

          for (size_t j = offset_first; j < offset_last; ++j) {
            auto e_op_result      = *(sample_e_op_results + j);
            auto unrenumbered_src = thrust::get<0>(e_op_result);
            auto unrenumbered_dst = thrust::get<1>(e_op_result);
            if (unrenumbered_src != *(mg_renumber_map_labels + v_offset)) { return true; }
            auto unrenumbered_nbr_first =
              unrenumbered_indices + *(unrenumbered_offsets + unrenumbered_src);
            auto unrenumbered_nbr_last =
              unrenumbered_indices + *(unrenumbered_offsets + (unrenumbered_src + vertex_t{1}));
            if (!thrust::binary_search(thrust::seq,
                                       unrenumbered_nbr_first,
                                       unrenumbered_nbr_last,
                                       unrenumbered_dst)) {  // assumed neighbor lists are sorted
              return true;
            }
            property_t src_val{};
            property_t dst_val{};
            if constexpr (cugraph::is_thrust_tuple_of_arithmetic<property_t>::value) {
              src_val =
                thrust::make_tuple(thrust::get<2>(e_op_result), thrust::get<3>(e_op_result));
              dst_val =
                thrust::make_tuple(thrust::get<4>(e_op_result), thrust::get<5>(e_op_result));
            } else {
              src_val = thrust::get<2>(e_op_result);
              dst_val = thrust::get<3>(e_op_result);
            }
            if (src_val != property_transform(unrenumbered_src)) { return true; }
            if (dst_val != property_transform(unrenumbered_dst)) { return true; }

            if (!with_replacement) {
              auto unrenumbered_dst_first =
                thrust::get<1>(sample_e_op_results.get_iterator_tuple()) + offset_first;
              auto unrenumbered_dst_last =
                thrust::get<1>(sample_e_op_results.get_iterator_tuple()) + offset_last;
              auto dst_count = thrust::count(
                thrust::seq,
                unrenumbered_dst_first,
                unrenumbered_dst_last,
                unrenumbered_dst);  // this could be inefficient for high-degree vertices, if we
                                    // sort [unrenumbered_dst_first, unrenumbered_dst_last) we can
                                    // use binary search but we may better not modify the sampling
                                    // output and allow inefficiency as this is just for testing
              auto multiplicity = thrust::distance(
                thrust::lower_bound(
                  thrust::seq, unrenumbered_nbr_first, unrenumbered_nbr_last, unrenumbered_dst),
                thrust::upper_bound(thrust::seq,
                                    unrenumbered_nbr_first,
                                    unrenumbered_nbr_last,
                                    unrenumbered_dst));  // this assumes neighbor lists are sorted
              if (dst_count > multiplicity) { return true; }
            }
          }

          return false;
        }));

      num_invalids = cugraph::host_scalar_allreduce(
        handle_->get_comms(), num_invalids, raft::comms::op_t::SUM, handle_->get_stream());
      ASSERT_TRUE(num_invalids == 0);
    }
  }

 private:
  static std::unique_ptr<raft::handle_t> handle_;
};

template <typename input_usecase_t>
std::unique_ptr<raft::handle_t>
  Tests_MGPerVRandomSelectTransformOutgoingE<input_usecase_t>::handle_ = nullptr;

using Tests_MGPerVRandomSelectTransformOutgoingE_File =
  Tests_MGPerVRandomSelectTransformOutgoingE<cugraph::test::File_Usecase>;
using Tests_MGPerVRandomSelectTransformOutgoingE_Rmat =
  Tests_MGPerVRandomSelectTransformOutgoingE<cugraph::test::Rmat_Usecase>;

TEST_P(Tests_MGPerVRandomSelectTransformOutgoingE_File, CheckInt32Int32FloatTupleIntFloat)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, thrust::tuple<int, float>>(std::get<0>(param),
                                                                       std::get<1>(param));
}

TEST_P(Tests_MGPerVRandomSelectTransformOutgoingE_Rmat, CheckInt32Int32FloatTupleIntFloat)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, thrust::tuple<int, float>>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGPerVRandomSelectTransformOutgoingE_Rmat, CheckInt32Int64FloatTupleIntFloat)
{
  auto param = GetParam();
  run_current_test<int32_t, int64_t, float, thrust::tuple<int, float>>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGPerVRandomSelectTransformOutgoingE_Rmat, CheckInt64Int64FloatTupleIntFloat)
{
  auto param = GetParam();
  run_current_test<int64_t, int64_t, float, thrust::tuple<int, float>>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGPerVRandomSelectTransformOutgoingE_File, CheckInt32Int32Float)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, int>(std::get<0>(param), std::get<1>(param));
}

TEST_P(Tests_MGPerVRandomSelectTransformOutgoingE_Rmat, CheckInt32Int32Float)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, int>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGPerVRandomSelectTransformOutgoingE_Rmat, CheckInt32Int64Float)
{
  auto param = GetParam();
  run_current_test<int32_t, int64_t, float, int>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGPerVRandomSelectTransformOutgoingE_Rmat, CheckInt64Int64Float)
{
  auto param = GetParam();
  run_current_test<int64_t, int64_t, float, int>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

INSTANTIATE_TEST_SUITE_P(
  file_test,
  Tests_MGPerVRandomSelectTransformOutgoingE_File,
  ::testing::Combine(
    ::testing::Values(Prims_Usecase{size_t{1000}, size_t{4}, false, false, false, true},
                      Prims_Usecase{size_t{1000}, size_t{4}, false, true, false, true},
                      Prims_Usecase{size_t{1000}, size_t{4}, true, false, false, true},
                      Prims_Usecase{size_t{1000}, size_t{4}, true, true, false, true}),
    ::testing::Values(cugraph::test::File_Usecase("test/datasets/karate.mtx"),
                      cugraph::test::File_Usecase("test/datasets/web-Google.mtx"),
                      cugraph::test::File_Usecase("test/datasets/ljournal-2008.mtx"),
                      cugraph::test::File_Usecase("test/datasets/webbase-1M.mtx"))));

INSTANTIATE_TEST_SUITE_P(
  rmat_small_test,
  Tests_MGPerVRandomSelectTransformOutgoingE_Rmat,
  ::testing::Combine(
    ::testing::Values(Prims_Usecase{size_t{1000}, size_t{4}, false, false, false, true},
                      Prims_Usecase{size_t{1000}, size_t{4}, false, true, false, true},
                      Prims_Usecase{size_t{1000}, size_t{4}, true, false, false, true},
                      Prims_Usecase{size_t{1000}, size_t{4}, true, true, false, true}),
    ::testing::Values(
      cugraph::test::Rmat_Usecase(10, 16, 0.57, 0.19, 0.19, 0, false, false, 0, true))));

INSTANTIATE_TEST_SUITE_P(
  rmat_benchmark_test, /* note that scale & edge factor can be overridden in benchmarking (with
                          --gtest_filter to select only the rmat_benchmark_test with a specific
                          vertex & edge type combination) by command line arguments and do not
                          include more than one Rmat_Usecase that differ only in scale or edge
                          factor (to avoid running same benchmarks more than once) */
  Tests_MGPerVRandomSelectTransformOutgoingE_Rmat,
  ::testing::Combine(
    ::testing::Values(Prims_Usecase{size_t{10000000}, size_t{25}, false, false, false, false},
                      Prims_Usecase{size_t{10000000}, size_t{25}, false, true, false, false},
                      Prims_Usecase{size_t{10000000}, size_t{25}, true, false, false, false},
                      Prims_Usecase{size_t{10000000}, size_t{25}, true, true, false, false}),
    ::testing::Values(
      cugraph::test::Rmat_Usecase(20, 32, 0.57, 0.19, 0.19, 0, false, false, 0, true))));

CUGRAPH_MG_TEST_PROGRAM_MAIN()
