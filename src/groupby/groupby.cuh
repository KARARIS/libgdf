/*
 * Copyright (c) 2018, NVIDIA CORPORATION.
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

#include <gdf/gdf.h>
#include <gdf/errorutils.h>
#include <cuda_runtime.h>
#include "hash/groupby_compute_api.h"
#include "hash/aggregation_operations.cuh"

/* --------------------------------------------------------------------------*/
/** 
 * @Synopsis Calls the Hash Based group by compute API to compute the groupby with 
 * aggregation.
 * 
 * @Param ncols The number of input group by columns
 * @Param in_groupby_columns[] The set of input groupby columns
 * @Param in_aggregation_column The input aggregation column
 * @Param out_groupby_columns[] The set of output groupby columns
 * @Param out_aggregation_column The output aggregation column
 * @Param sort_result Flag to optionally sort the output
 * @tparam groupby_type The type of the groupby column
 * @tparam aggregation_type  The type of the aggregation column
 * @tparam op A binary functor that implements the aggregation operation
 * 
 * @Returns On failure, returns appropriate error code. Otherwise, GDF_SUCCESS
 */
/* ----------------------------------------------------------------------------*/
template <typename groupby_type, typename aggregation_type, template <typename T> class op>
gdf_error dispatched_groupby(int ncols,               
                             gdf_column* in_groupby_columns[],        
                             gdf_column* in_aggregation_column,       
                             gdf_column* out_groupby_columns[],
                             gdf_column* out_aggregation_column,
                             bool sort_result = false)
{

  // Template the functor on the type of the aggregation column
  using op_type = op<aggregation_type>;

  // Cast the void* data to the appropriate type
  groupby_type * in_group_col = static_cast<groupby_type *>(in_groupby_columns[0]->data);
  aggregation_type * in_agg_col = static_cast<aggregation_type *>(in_aggregation_column->data);
  groupby_type * out_group_col = static_cast<groupby_type *>(out_groupby_columns[0]->data);

  // TODO Need to allow for the aggregation output type to be different from the aggregation input type
  aggregation_type * out_agg_col = static_cast<aggregation_type *>(out_aggregation_column->data);

  const gdf_size_type in_size = in_groupby_columns[0]->size;
  gdf_size_type out_size{0};

  if(cudaSuccess != GroupbyHash(in_group_col, in_agg_col, in_size, 
                                out_group_col, out_agg_col, &out_size, op_type(), sort_result))
  {
    return GDF_CUDA_ERROR;
  }

  // Update the size of the result
  out_groupby_columns[0]->size = out_size;
  out_aggregation_column->size = out_size;

  return GDF_SUCCESS;
}

template <template <typename> class, template<typename> class>
struct is_same_functor : std::false_type{};

template <template <typename> class T>
struct is_same_functor<T,T> : std::true_type{};

/* --------------------------------------------------------------------------*/
/** 
 * @Synopsis  Helper function for gdf_groupby_hash. Deduces the type of the aggregation
 * column and calls another function to perform the group by.
 * 
 */
/* ----------------------------------------------------------------------------*/
template <typename groupby_type, template <typename T> class op>
gdf_error dispatch_aggregation_type(int ncols,               
                                    gdf_column* in_groupby_columns[],        
                                    gdf_column* in_aggregation_column,       
                                    gdf_column* out_groupby_columns[],
                                    gdf_column* out_aggregation_column,
                                    bool sort_result = false)
{


  gdf_dtype aggregation_column_type;

  // FIXME When the aggregation type is COUNT, use the type of the OUTPUT column
  // as the type of the aggregation column. This is required as there is a limitation 
  // hash based groupby implementation where it's assumed the aggregation input column
  if(is_same_functor<count_op, op>::value)
  {
    aggregation_column_type = out_aggregation_column->dtype;
  }
  else
  {
    aggregation_column_type = in_aggregation_column->dtype;
  }

  // Deduce the type of the aggregation column and call function to perform GroupBy
  switch(aggregation_column_type)
  {
    case GDF_INT8:   
      { 
        return dispatched_groupby<groupby_type, int8_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                            out_groupby_columns, out_aggregation_column, sort_result);
      }
    case GDF_INT16:  
      { 
        return dispatched_groupby<groupby_type, int16_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                             out_groupby_columns, out_aggregation_column, sort_result);
      }
    case GDF_INT32:  
      { 
        return dispatched_groupby<groupby_type, int32_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                             out_groupby_columns, out_aggregation_column, sort_result);
      }
    case GDF_INT64:  
      { 
        return dispatched_groupby<groupby_type, int64_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                             out_groupby_columns, out_aggregation_column, sort_result);
      }
    case GDF_FLOAT32:
      { 
        return dispatched_groupby<groupby_type, float, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                            out_groupby_columns, out_aggregation_column, sort_result);
      }
    case GDF_FLOAT64:
      { 
        return dispatched_groupby<groupby_type, double, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                           out_groupby_columns, out_aggregation_column, sort_result);
      }
    default:
      std::cout << "Unsupported aggregation column type: " << aggregation_column_type << std::endl;
      return GDF_UNSUPPORTED_DTYPE;
  }
}

/* --------------------------------------------------------------------------*/
/** 
 * @Synopsis  Helper function for gdf_group_by hash. Deduces the type of the input
 * group by gdf_column and sets a template parameter accordingly to another dispatch
 * dispatch function.
 * 
 */
/* ----------------------------------------------------------------------------*/
template <template <typename T> class op>
gdf_error dispatch_groupby_type(int ncols,               
                                gdf_column* in_groupby_columns[],        
                                gdf_column* in_aggregation_column,       
                                gdf_column* out_groupby_columns[],
                                gdf_column* out_aggregation_column,
                                bool sort_result = false)
{
  gdf_dtype groupby_column_type = in_groupby_columns[0]->dtype;

  // Deduce the type of the groupby column and call function to deduce the aggregation column type
  switch(groupby_column_type)
  {
    case GDF_INT8:   
      {
        return dispatch_aggregation_type<int8_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                     out_groupby_columns, out_aggregation_column, sort_result);
      }
    case GDF_INT16:  
      { 
        return dispatch_aggregation_type<int16_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                      out_groupby_columns, out_aggregation_column, sort_result);
      }
    case GDF_INT32:  
      { 
        return dispatch_aggregation_type<int32_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                      out_groupby_columns, out_aggregation_column, sort_result);
      }
    case GDF_INT64:  
      { 
        return dispatch_aggregation_type<int64_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                      out_groupby_columns, out_aggregation_column, sort_result);
      }
    // For floating point groupby column types, cast to an integral type
    case GDF_FLOAT32:
      {
        return dispatch_aggregation_type<int32_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                      out_groupby_columns, out_aggregation_column, sort_result);
      }
    case GDF_FLOAT64:
      { 
        return dispatch_aggregation_type<int64_t, op>(ncols, in_groupby_columns, in_aggregation_column, 
                                                      out_groupby_columns, out_aggregation_column, sort_result);
      }
    default:
     {
       std::cout << "Unsupported groupby column type:" << groupby_column_type << std::endl;
       return GDF_UNSUPPORTED_DTYPE;
     }
  }

}

/* --------------------------------------------------------------------------*/
/** 
 * @Synopsis  This function provides the libgdf entry point for a hash-based group-by.
 * Performs a Group-By operation on an arbitrary number of columns with a single aggregation column.
 * 
 * @Param[in] ncols The number of columns to group-by
 * @Param[in] in_groupby_columns[] The columns to group-by
 * @Param[in,out] in_aggregation_column The column to perform the aggregation on
 * @Param[in,out] out_groupby_columns[] A preallocated buffer to store the resultant group-by columns
 * @Param[in,out] out_aggregation_column A preallocated buffer to store the resultant aggregation column
 * @tparam[in] aggregation_operation A functor that defines the aggregation operation
 * 
 * @Returns gdf_error
 */
/* ----------------------------------------------------------------------------*/
template <template <typename aggregation_type> class aggregation_operation>
gdf_error gdf_group_by_hash(int ncols,               
                            gdf_column* in_groupby_columns[],        
                            gdf_column* in_aggregation_column,       
                            gdf_column* out_groupby_columns[],
                            gdf_column* out_aggregation_column,
                            bool sort_result = false)
{

  // TODO Currently only supports a single groupby column
  if(ncols > 1) {
    std::cerr << "Can only support a single groupby column at this time.\n";
    return GDF_GROUPBY_TOO_MANY_COLUMNS;
  }

  return dispatch_groupby_type<aggregation_operation>(ncols, in_groupby_columns, in_aggregation_column, 
                                                      out_groupby_columns, out_aggregation_column, sort_result);
}

/* --------------------------------------------------------------------------*/
/** 
 * @Synopsis  Creates a gdf_column of a specified size and data type
 * 
 * @Param size The number of elements in the gdf_column
 * @tparam col_type The datatype of the gdf_column
 * 
 * @Returns   
 */
/* ----------------------------------------------------------------------------*/
template<typename col_type>
gdf_column create_gdf_column(const size_t size)
{
  gdf_column the_column;

  // Deduce the type and set the gdf_dtype accordingly
  gdf_dtype gdf_col_type;
  if(std::is_same<col_type,int8_t>::value) gdf_col_type = GDF_INT8;
  else if(std::is_same<col_type,uint8_t>::value) gdf_col_type = GDF_INT8;
  else if(std::is_same<col_type,int16_t>::value) gdf_col_type = GDF_INT16;
  else if(std::is_same<col_type,uint16_t>::value) gdf_col_type = GDF_INT16;
  else if(std::is_same<col_type,int32_t>::value) gdf_col_type = GDF_INT32;
  else if(std::is_same<col_type,uint32_t>::value) gdf_col_type = GDF_INT32;
  else if(std::is_same<col_type,int64_t>::value) gdf_col_type = GDF_INT64;
  else if(std::is_same<col_type,uint64_t>::value) gdf_col_type = GDF_INT64;
  else if(std::is_same<col_type,float>::value) gdf_col_type = GDF_FLOAT32;
  else if(std::is_same<col_type,double>::value) gdf_col_type = GDF_FLOAT64;
  else assert(false && "Invalid type passed to create_gdf_column");

  // Fill the gdf_column struct
  the_column.size = size;
  the_column.dtype = gdf_col_type;
  the_column.valid = nullptr;
  gdf_dtype_extra_info extra_info;
  extra_info.time_unit = TIME_UNIT_NONE;
  the_column.dtype_info = extra_info;

  // Allocate the buffer for the column
  cudaMalloc(&the_column.data, the_column.size * sizeof(col_type));

  return the_column;
}

/* --------------------------------------------------------------------------*/
/** 
 * @Synopsis Given a column for the SUM and COUNT aggregations, computes the AVG
 * aggregation column result as AVG[i] = SUM[i] / COUNT[i].
 * 
 * @Param[out] avg_column The output AVG aggregation column
 * @Param count_column The input COUNT aggregation column
 * @Param sum_column The input SUM aggregation column
 * @tparam sum_type The type used for the SUM column
 * @tparam avg_type The type used for the AVG column
 */
/* ----------------------------------------------------------------------------*/
template <typename sum_type, typename avg_type>
void compute_average(gdf_column * avg_column, gdf_column const & count_column, gdf_column const & sum_column)
{
  const size_t output_size = count_column.size;

  // Wrap raw device pointers in thrust device ptrs to enable usage of thrust::transform
  thrust::device_ptr<sum_type> d_sums = thrust::device_pointer_cast(static_cast<sum_type*>(sum_column.data));
  thrust::device_ptr<size_t> d_counts = thrust::device_pointer_cast(static_cast<size_t*>(count_column.data));
  thrust::device_ptr<avg_type> d_avg  = thrust::device_pointer_cast(static_cast<avg_type*>(avg_column->data));

  auto average_op =  [] __device__ (sum_type sum, size_t count)->avg_type { return (sum / static_cast<avg_type>(count)); };

  // Computes the average into the passed in output buffer for the average column
  thrust::transform(d_sums, d_sums + output_size, d_counts, d_avg, average_op);

  // Update the size of the average column
  avg_column->size = output_size;
}

/* --------------------------------------------------------------------------*/
/** 
 * @Synopsis Computes the SUM and COUNT aggregations for the group by inputs. Calls 
 * another function to compute the AVG aggregator based on the SUM and COUNT results.
 * 
 * @Param ncols The number of input groupby columns
 * @Param in_groupby_columns[] The groupby input columns
 * @Param in_aggregation_column The aggregation input column
 * @Param out_groupby_columns[] The output groupby columns
 * @Param out_aggregation_column The output aggregation column
 * @tparam sum_type The type used for the SUM aggregation output column
 * 
 * @Returns gdf_error with error code on failure, otherwise GDF_SUCCESS
 */
/* ----------------------------------------------------------------------------*/
template <typename sum_type>
gdf_error multi_pass_avg(int ncols,               
                         gdf_column* in_groupby_columns[],        
                         gdf_column* in_aggregation_column,       
                         gdf_column* out_groupby_columns[],
                         gdf_column* out_aggregation_column)
{
  // Allocate intermediate output gdf_columns for the output of the Count and Sum aggregations
  const size_t output_size = out_aggregation_column->size;

  // Make sure the result is sorted so the output is in identical order
  bool sort_result = true;

  // FIXME Currently, hash based groupby assumes the type of the input aggregation column and 
  // the output aggregation column are the same. This doesn't work for COUNT

  // Compute the counts for each key 
  gdf_column count_output = create_gdf_column<size_t>(output_size);
  gdf_group_by_hash<count_op>(ncols, in_groupby_columns, in_aggregation_column, out_groupby_columns, &count_output, sort_result);

  // Compute the sum for each key. Should be okay to reuse the groupby column output
  gdf_column sum_output = create_gdf_column<sum_type>(output_size);
  gdf_group_by_hash<sum_op>(ncols, in_groupby_columns, in_aggregation_column, out_groupby_columns, &sum_output, sort_result); 

  // Compute the average from the Sum and Count columns and store into the passed in aggregation output buffer
  const gdf_dtype gdf_output_type = out_aggregation_column->dtype;
  switch(gdf_output_type){
    case GDF_INT8:    { compute_average<sum_type, int8_t>( out_aggregation_column, count_output, sum_output); break; }
    case GDF_INT16:   { compute_average<sum_type, int16_t>( out_aggregation_column, count_output, sum_output); break; }
    case GDF_INT32:   { compute_average<sum_type, int32_t>( out_aggregation_column, count_output, sum_output); break; }
    case GDF_INT64:   { compute_average<sum_type, int64_t>( out_aggregation_column, count_output, sum_output); break; }
    case GDF_FLOAT32: { compute_average<sum_type, float>( out_aggregation_column, count_output, sum_output); break; }
    case GDF_FLOAT64: { compute_average<sum_type, double>( out_aggregation_column, count_output, sum_output); break; }
    default: return GDF_UNSUPPORTED_DTYPE;
  }

  // Free intermediate storage
  cudaFree(count_output.data);
  cudaFree(sum_output.data);

  return GDF_SUCCESS;
}

/* --------------------------------------------------------------------------*/
/** 
 * @Synopsis  Computes the AVG aggregation for a hash-based group by. This aggregator
 * requires its own function as AVG is implemented via the COUNT and SUM aggregators.
 * 
 * @Param ncols The number of columns to groupby
 * @Param in_groupby_columns[] The input groupby columns
 * @Param in_aggregation_column The input aggregation column
 * @Param out_groupby_columns[] The output groupby columns
 * @Param out_aggregation_column The output aggregation column
 * 
 * @Returns gdf_error with error code on failure, otherwise GDF_SUCESS
 */
/* ----------------------------------------------------------------------------*/
gdf_error gdf_group_by_hash_avg(int ncols,               
                                gdf_column* in_groupby_columns[],        
                                gdf_column* in_aggregation_column,       
                                gdf_column* out_groupby_columns[],
                                gdf_column* out_aggregation_column)
{

  assert( (ncols == 1 ) && "Hash-based groupby only supports a single input column at this time." );

  // Deduce the type used for the SUM aggregation, assuming we use the same type as the aggregation column
  const gdf_dtype gdf_sum_type = in_aggregation_column->dtype;
  switch(gdf_sum_type){
    case GDF_INT8:   { return multi_pass_avg<int8_t>(ncols, in_groupby_columns, in_aggregation_column, out_groupby_columns, out_aggregation_column);}
    case GDF_INT16:  { return multi_pass_avg<int16_t>(ncols, in_groupby_columns, in_aggregation_column, out_groupby_columns, out_aggregation_column);}
    case GDF_INT32:  { return multi_pass_avg<int32_t>(ncols, in_groupby_columns, in_aggregation_column, out_groupby_columns, out_aggregation_column);}
    case GDF_INT64:  { return multi_pass_avg<int64_t>(ncols, in_groupby_columns, in_aggregation_column, out_groupby_columns, out_aggregation_column);}
    case GDF_FLOAT32:{ return multi_pass_avg<float>(ncols, in_groupby_columns, in_aggregation_column, out_groupby_columns, out_aggregation_column);}
    case GDF_FLOAT64:{ return multi_pass_avg<double>(ncols, in_groupby_columns, in_aggregation_column, out_groupby_columns, out_aggregation_column);}
    default: return GDF_UNSUPPORTED_DTYPE;
  }

  return GDF_SUCCESS;
}


