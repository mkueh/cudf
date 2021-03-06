/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <cudf/column/column.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/detail/copy_if.cuh>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/strings/detail/utilities.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/utilities/error.hpp>
#include <nvtext/generate_ngrams.hpp>
#include <strings/utilities.cuh>

namespace nvtext {
namespace detail {
namespace {
/**
 * @brief Generate ngrams from strings column.
 *
 * Adjacent strings are concatented with the provided separator.
 * The number of adjacent strings join depends on the specified ngrams value.
 * For example: for bigrams (ngrams=2), pairs of strings are concatenated.
 */
struct ngram_generator_fn {
  cudf::column_device_view const d_strings;
  cudf::size_type ngrams;
  cudf::string_view const d_separator;
  int32_t const* d_offsets{};
  char* d_chars{};

  /**
   * @brief Build ngram for each string.
   *
   * This is called for each thread and processed for each string.
   * Each string will produce the number of ngrams specified.
   *
   * @param idx Index of the kernel thread.
   * @return Number of bytes required for the string for this thread.
   */
  __device__ cudf::size_type operator()(cudf::size_type idx)
  {
    char* out_ptr         = d_chars ? d_chars + d_offsets[idx] : nullptr;
    cudf::size_type bytes = 0;
    for (cudf::size_type n = 0; n < ngrams; ++n) {
      auto const d_str = d_strings.element<cudf::string_view>(n + idx);
      bytes += d_str.size_bytes();
      if (out_ptr) out_ptr = cudf::strings::detail::copy_string(out_ptr, d_str);
      if ((n + 1) >= ngrams) continue;
      bytes += d_separator.size_bytes();
      if (out_ptr) out_ptr = cudf::strings::detail::copy_string(out_ptr, d_separator);
    }
    return bytes;
  }
};

}  // namespace

std::unique_ptr<cudf::column> generate_ngrams(
  cudf::strings_column_view const& strings,
  cudf::size_type ngrams               = 2,
  cudf::string_scalar const& separator = cudf::string_scalar{"_"},
  rmm::mr::device_memory_resource* mr  = rmm::mr::get_default_resource(),
  cudaStream_t stream                  = 0)
{
  CUDF_EXPECTS(separator.is_valid(), "Parameter separator must be valid");
  cudf::string_view const d_separator(separator.data(), separator.size());
  CUDF_EXPECTS(ngrams > 1, "Parameter ngrams should be an integer value of 2 or greater");

  auto strings_count = strings.size();
  if (strings_count == 0)  // if no strings, return an empty column
    return cudf::make_empty_column(cudf::data_type{cudf::STRING});

  auto execpol        = rmm::exec_policy(stream);
  auto strings_column = cudf::column_device_view::create(strings.parent(), stream);
  auto d_strings      = *strings_column;

  // first create a new offsets vector removing nulls and empty strings from the input column
  std::unique_ptr<cudf::column> non_empty_offsets_column = [&] {
    cudf::column_view offsets_view(
      cudf::data_type{cudf::INT32}, strings_count + 1, strings.offsets().data<int32_t>());
    auto table_offsets = cudf::experimental::detail::copy_if(
                           cudf::table_view({offsets_view}),
                           [d_strings, strings_count] __device__(cudf::size_type idx) {
                             if (idx == strings_count) return true;
                             if (d_strings.is_null(idx)) return false;
                             return !d_strings.element<cudf::string_view>(idx).empty();
                           },
                           mr,
                           stream)
                           ->release();
    strings_count = table_offsets.front()->size() - 1;
    return std::move(table_offsets.front());
  }();  // this allows freeint the temporary table_offsets

  CUDF_EXPECTS(strings_count >= ngrams, "Insufficient number of strings to generate ngrams");
  // create a temporary column view from the non-empty offsets and chars column views
  cudf::column_view strings_view(cudf::data_type{cudf::STRING},
                                 strings_count,
                                 nullptr,
                                 nullptr,
                                 0,
                                 0,
                                 {non_empty_offsets_column->view(), strings.chars()});
  strings_column = cudf::column_device_view::create(strings_view, stream);
  d_strings      = *strings_column;

  // compute the number of strings of ngrams
  auto const ngrams_count = strings_count - ngrams + 1;

  // build output offsets by computing the output bytes for each generated ngram
  auto offsets_transformer_itr =
    thrust::make_transform_iterator(thrust::make_counting_iterator<cudf::size_type>(0),
                                    ngram_generator_fn{d_strings, ngrams, d_separator});
  auto offsets_column = cudf::strings::detail::make_offsets_child_column(
    offsets_transformer_itr, offsets_transformer_itr + ngrams_count, mr, stream);
  auto d_offsets = offsets_column->view().data<int32_t>();

  // build the chars column
  // generate the ngrams from the input strings and copy them into the chars data buffer
  cudf::size_type const total_bytes = thrust::device_pointer_cast(d_offsets)[ngrams_count];
  auto chars_column =
    cudf::strings::detail::create_chars_child_column(ngrams_count, 0, total_bytes, mr, stream);
  char* const d_chars = chars_column->mutable_view().data<char>();
  thrust::for_each_n(execpol->on(stream),
                     thrust::make_counting_iterator<cudf::size_type>(0),
                     ngrams_count,
                     ngram_generator_fn{d_strings, ngrams, d_separator, d_offsets, d_chars});
  chars_column->set_null_count(0);

  // make the output strings column from the offsets and chars column
  return cudf::make_strings_column(ngrams_count,
                                   std::move(offsets_column),
                                   std::move(chars_column),
                                   0,
                                   rmm::device_buffer{},
                                   stream,
                                   mr);
}

}  // namespace detail

std::unique_ptr<cudf::column> generate_ngrams(cudf::strings_column_view const& strings,
                                              cudf::size_type ngrams,
                                              cudf::string_scalar const& separator,
                                              rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::generate_ngrams(strings, ngrams, separator, mr);
}

}  // namespace nvtext
