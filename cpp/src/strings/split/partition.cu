/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
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
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/strings/split/partition.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/utilities/error.hpp>
#include <strings/utilities.hpp>

#include <vector>

namespace cudf
{
namespace strings
{
namespace detail
{

using string_index_pair = thrust::pair<const char*,size_type>;

namespace
{

//
// Partition is split the string at the first occurrence of delimiter, and return 3 elements containing
// the part before the delimiter, the delimiter itself, and the part after the delimiter.
// If the delimiter is not found, return 3 elements containing the string itself, followed by two empty strings.
//
// >>> import pandas as pd
// >>> strs = pd.Series(['héllo', None, 'a_bc_déf', 'a__bc', '_ab_cd', 'ab_cd_'])
// >>> strs.str.partition('_')
//        0     1       2
// 0  héllo
// 1   None  None    None
// 2      a     _  bc_déf
// 3      a     _     _bc
// 4            _   ab_cd
// 5     ab     _     cd_
//
struct partition_fn
{
    column_device_view const d_strings;  // strings to split
    string_view const d_delimiter;       // delimiter for split
    string_index_pair* d_indices_left{};
    string_index_pair* d_indices_delim{};
    string_index_pair* d_indices_right{};

    partition_fn( column_device_view const& d_strings, string_view const& d_delimiter,
                  string_index_pair* d_indices_left = nullptr,
                  string_index_pair* d_indices_delim = nullptr,
                  string_index_pair* d_indices_right = nullptr)
                : d_strings(d_strings), d_delimiter(d_delimiter),
                  d_indices_left(d_indices_left), d_indices_delim(d_indices_delim), d_indices_right(d_indices_right) {}

    __device__ void set_null_entries( size_type idx )
    {
        if( d_indices_left )
        {
            d_indices_left[idx] = string_index_pair{nullptr,0};
            d_indices_delim[idx] = string_index_pair{nullptr,0};
            d_indices_right[idx] = string_index_pair{nullptr,0};
        }
    }

    __device__ size_type check_delimiter( size_type idx, string_view const& d_str, size_type offset, char_utf8 chr )
    {
        size_type pos = -1;
        if( d_delimiter.empty() )
        {
            if( chr <= ' ' )  // whitespace delimited
                pos = offset;
        }
        else
        {
            if( d_delimiter.compare(d_str.data()+offset, d_str.size_bytes()-offset)==0 )
                pos = offset;
        }
        if( pos >=0 ) // delimiter found, set results
        {
            d_indices_left[idx] = string_index_pair{d_str.data(),offset};
            d_indices_delim[idx] = string_index_pair{d_delimiter.data(),d_delimiter.size_bytes()};
            offset += d_delimiter.size_bytes();
            d_indices_right[idx] = string_index_pair{d_str.data() + offset,d_str.size_bytes() - offset};
        }
        return pos;
    }

    __device__ void delimiter_not_found(size_type idx, string_view const& d_str)
    {
        d_indices_left[idx] = string_index_pair{d_str.data(),d_str.size_bytes()};
        d_indices_delim[idx] = string_index_pair{d_str.data(),0}; // two empty
        d_indices_right[idx] = string_index_pair{d_str.data(),0}; // strings added
    }

    __device__ void operator()(size_type idx)
    {
        if( d_strings.is_null(idx) )
        {
            set_null_entries(idx);
            return;
        }
        string_view d_str = d_strings.element<string_view>(idx);
        size_type pos = -1;
        for( auto itr=d_str.begin(); itr < d_str.end(); ++itr )
        {
            auto offset = itr.byte_offset();
            pos = check_delimiter(idx,d_str,offset,*itr);
            if( pos >= 0 )
                break;
        }
        if( pos < 0 ) // delimiter not found
            delimiter_not_found(idx,d_str);
    }
};

//
// This follows most of the same logic as partition above except that the delimiter
// search starts from the end of the string. Also, if no delimiter is found the
// resulting array includes two empty strings followed by the original string.
//
// >>> import pandas as pd
// >>> strs = pd.Series(['héllo', None, 'a_bc_déf', 'a__bc', '_ab_cd', 'ab_cd_'])
// >>> strs.str.rpartition('_')
//        0     1      2
// 0               héllo
// 1   None  None   None
// 2   a_bc     _    déf
// 3     a_     _     bc
// 4    _ab     _     cd
// 5  ab_cd     _
//
struct rpartition_fn : public partition_fn
{
    rpartition_fn( column_device_view const& d_strings, string_view const& d_delimiter,
                  string_index_pair* d_indices_left = nullptr,
                  string_index_pair* d_indices_delim = nullptr,
                  string_index_pair* d_indices_right = nullptr)
                : partition_fn(d_strings, d_delimiter, d_indices_left, d_indices_delim, d_indices_right) {}

    __device__ void operator()(size_type idx)
    {
        if( d_strings.is_null(idx) )
        {
            set_null_entries(idx);
            return;
        }
        string_view d_str = d_strings.element<string_view>(idx);
        size_type pos = -1;
        auto itr = d_str.end();
        if( d_str.length() > d_delimiter.length() )
            itr -= d_delimiter.length();
        while( d_str.begin() < itr )
        {
            --itr;
            auto offset = itr.byte_offset();
            pos = check_delimiter(idx,d_str,offset,*itr);
            if( pos >= 0 )
                break;
        }
        if( pos < 0 ) // delimiter not found
            delimiter_not_found(idx,d_str);
    }
};

} // namespace


std::unique_ptr<experimental::table> partition( strings_column_view const& strings,
                                                string_scalar const& delimiter = string_scalar(""),
                                                rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                                cudaStream_t stream = 0 )
{
    CUDF_EXPECTS( delimiter.is_valid(), "Parameter delimiter must be valid");
    std::vector<std::unique_ptr<column>> results;
    auto strings_count = strings.size();
    if( strings_count == 0 )
        return std::make_unique<experimental::table>(std::move(results));
    auto strings_column = column_device_view::create(strings.parent(),stream);
    column_device_view d_strings = *strings_column;
    string_view d_delimiter(delimiter.data(),delimiter.size());
    rmm::device_vector<string_index_pair> left_indices(strings_count), delim_indices(strings_count), right_indices(strings_count);
    partition_fn partitioner(d_strings,d_delimiter,left_indices.data().get(),delim_indices.data().get(),right_indices.data().get());

    thrust::for_each_n( rmm::exec_policy(stream)->on(stream), thrust::make_counting_iterator<size_type>(0), strings_count, partitioner);
    results.emplace_back(make_strings_column(left_indices,stream,mr));
    results.emplace_back(make_strings_column(delim_indices,stream,mr));
    results.emplace_back(make_strings_column(right_indices,stream,mr));
    return std::make_unique<experimental::table>(std::move(results));
}

std::unique_ptr<experimental::table> rpartition( strings_column_view const& strings,
                                                 string_scalar const& delimiter = string_scalar(""),
                                                 rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                                 cudaStream_t stream = 0 )
{
    CUDF_EXPECTS( delimiter.is_valid(), "Parameter delimiter must be valid");
    std::vector<std::unique_ptr<column>> results;
    auto strings_count = strings.size();
    if( strings_count == 0 )
        return std::make_unique<experimental::table>(std::move(results));
    auto strings_column = column_device_view::create(strings.parent(),stream);
    column_device_view d_strings = *strings_column;
    string_view d_delimiter(delimiter.data(),delimiter.size());
    rmm::device_vector<string_index_pair> left_indices(strings_count), delim_indices(strings_count), right_indices(strings_count);
    rpartition_fn partitioner(d_strings,d_delimiter,left_indices.data().get(),delim_indices.data().get(),right_indices.data().get());
    thrust::for_each_n( rmm::exec_policy(stream)->on(stream), thrust::make_counting_iterator<size_type>(0), strings_count, partitioner);

    results.emplace_back(make_strings_column(left_indices,stream,mr));
    results.emplace_back(make_strings_column(delim_indices,stream,mr));
    results.emplace_back(make_strings_column(right_indices,stream,mr));
    return std::make_unique<experimental::table>(std::move(results));
}

} // namespace detail

// external APIs

std::unique_ptr<experimental::table> partition( strings_column_view const& strings,
                                                string_scalar const& delimiter,
                                                rmm::mr::device_memory_resource* mr )
{
    return detail::partition( strings, delimiter, mr );
}

std::unique_ptr<experimental::table> rpartition( strings_column_view const& strings,
                                                 string_scalar const& delimiter,
                                                 rmm::mr::device_memory_resource* mr)
{
    return detail::rpartition( strings, delimiter, mr );
}

} // namespace strings
} // namespace cudf
