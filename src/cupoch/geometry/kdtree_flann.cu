/**
 * Copyright (c) 2020 Neka-Nat
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
**/
#include "cupoch/geometry/kdtree_flann.h"
#define FLANN_USE_CUDA
#include <flann/flann.hpp>

#include "cupoch/geometry/pointcloud.h"
#include "cupoch/geometry/trianglemesh.h"
#include "cupoch/utility/console.h"
#include "cupoch/utility/eigen.h"
#include "cupoch/utility/helper.h"

using namespace cupoch;
using namespace cupoch::geometry;

namespace {

template <int Dim>
struct convert_float4_functor {
    __device__ float4_t operator()(const Eigen::Matrix<float, Dim, 1> &x) const;
};

template <>
__device__ float4_t
convert_float4_functor<3>::operator()(const Eigen::Vector3f &x) const {
    return make_float4_t(x[0], x[1], x[2], 0.0f);
}

template <>
__device__ float4_t
convert_float4_functor<2>::operator()(const Eigen::Vector2f &x) const {
    return make_float4_t(x[0], x[1], 0.0f, 0.0f);
}

}  // namespace

KDTreeFlann::KDTreeFlann() {}

KDTreeFlann::KDTreeFlann(const Geometry &data) { SetGeometry(data); }

KDTreeFlann::~KDTreeFlann() {}

bool KDTreeFlann::SetGeometry(const Geometry &geometry) {
    switch (geometry.GetGeometryType()) {
        case Geometry::GeometryType::PointCloud:
            return SetRawData(((const PointCloud &)geometry).points_);
        case Geometry::GeometryType::TriangleMesh:
            return SetRawData(((const TriangleMesh &)geometry).vertices_);
        case Geometry::GeometryType::Image:
        case Geometry::GeometryType::Unspecified:
        default:
            utility::LogWarning(
                    "[KDTreeFlann::SetGeometry] Unsupported Geometry type.");
            return false;
    }
}

template <typename T>
int KDTreeFlann::Search(const utility::device_vector<T> &query,
                        const KDTreeSearchParam &param,
                        utility::device_vector<int> &indices,
                        utility::device_vector<float> &distance2) const {
    switch (param.GetSearchType()) {
        case KDTreeSearchParam::SearchType::Knn:
            return SearchKNN(query, ((const KDTreeSearchParamKNN &)param).knn_,
                             indices, distance2);
        case KDTreeSearchParam::SearchType::Radius:
            return SearchRadius(
                    query, ((const KDTreeSearchParamRadius &)param).radius_,
                    indices, distance2);
        case KDTreeSearchParam::SearchType::Hybrid:
            return SearchHybrid(
                    query, ((const KDTreeSearchParamHybrid &)param).radius_,
                    ((const KDTreeSearchParamHybrid &)param).max_nn_, indices,
                    distance2);
        default:
            return -1;
    }
    return -1;
}

template <typename T>
int KDTreeFlann::SearchKNN(const utility::device_vector<T> &query,
                           int knn,
                           utility::device_vector<int> &indices,
                           utility::device_vector<float> &distance2) const {
    // This is optimized code for heavily repeated search.
    // Other flann::Index::knnSearch() implementations lose performance due to
    // memory allocation/deallocation.
    if (data_.empty() || query.empty() || dataset_size_ <= 0 || knn < 0 ||
        knn > NUM_MAX_NN)
        return -1;
    T query0 = query[0];
    if (size_t(query0.size()) != dimension_) return -1;
    convert_float4_functor<T::RowsAtCompileTime> func;
    utility::device_vector<float4_t> query_f4(query.size());
    thrust::transform(query.begin(), query.end(), query_f4.begin(), func);
    flann::Matrix<float> query_flann(
            (float *)(thrust::raw_pointer_cast(query_f4.data())), query.size(),
            dimension_, sizeof(float) * 4);
    const int total_size = query.size() * knn;
    indices.resize(total_size);
    distance2.resize(total_size);
    flann::Matrix<int> indices_flann(thrust::raw_pointer_cast(indices.data()),
                                     query_flann.rows, knn);
    flann::Matrix<float> dists_flann(thrust::raw_pointer_cast(distance2.data()),
                                     query_flann.rows, knn);
    flann::SearchParams param;
    param.matrices_in_gpu_ram = true;
    int k = flann_index_->knnSearch(query_flann, indices_flann, dists_flann,
                                    knn, param);
    return k;
}

template <typename T>
int KDTreeFlann::SearchRadius(const utility::device_vector<T> &query,
                              float radius,
                              utility::device_vector<int> &indices,
                              utility::device_vector<float> &distance2) const {
    // This is optimized code for heavily repeated search.
    // Since max_nn is not given, we let flann to do its own memory management.
    // Other flann::Index::radiusSearch() implementations lose performance due
    // to memory management and CPU caching.
    if (data_.empty() || query.empty() || dataset_size_ <= 0) return -1;
    T query0 = query[0];
    if (size_t(query0.size()) != dimension_) return -1;
    convert_float4_functor<T::RowsAtCompileTime> func;
    utility::device_vector<float4_t> query_f4(query.size());
    thrust::transform(query.begin(), query.end(), query_f4.begin(), func);
    flann::Matrix<float> query_flann(
            (float *)(thrust::raw_pointer_cast(query_f4.data())), query.size(),
            dimension_, sizeof(float) * 4);
    flann::SearchParams param(-1, 0.0);
    param.max_neighbors = NUM_MAX_NN;
    param.matrices_in_gpu_ram = true;
    indices.resize(query.size() * NUM_MAX_NN);
    distance2.resize(query.size() * NUM_MAX_NN);
    flann::Matrix<int> indices_flann(thrust::raw_pointer_cast(indices.data()),
                                     query_flann.rows, NUM_MAX_NN);
    flann::Matrix<float> dists_flann(thrust::raw_pointer_cast(distance2.data()),
                                     query_flann.rows, NUM_MAX_NN);
    int k = flann_index_->radiusSearch(query_flann, indices_flann, dists_flann,
                                       float(radius * radius), param);
    return k;
}

template <typename T>
int KDTreeFlann::SearchHybrid(const utility::device_vector<T> &query,
                              float radius,
                              int max_nn,
                              utility::device_vector<int> &indices,
                              utility::device_vector<float> &distance2) const {
    // This is optimized code for heavily repeated search.
    // It is also the recommended setting for search.
    // Other flann::Index::radiusSearch() implementations lose performance due
    // to memory allocation/deallocation.
    if (data_.empty() || query.empty() || dataset_size_ <= 0 || max_nn < 0)
        return -1;
    T query0 = query[0];
    if (size_t(query0.size()) != dimension_) return -1;
    convert_float4_functor<T::RowsAtCompileTime> func;
    utility::device_vector<float4_t> query_f4(query.size());
    thrust::transform(query.begin(), query.end(), query_f4.begin(), func);
    flann::Matrix<float> query_flann(
            (float *)(thrust::raw_pointer_cast(query_f4.data())), query.size(),
            dimension_, sizeof(float) * 4);
    flann::SearchParams param(-1, 0.0);
    param.max_neighbors = max_nn;
    param.matrices_in_gpu_ram = true;
    indices.resize(query.size() * max_nn);
    distance2.resize(query.size() * max_nn);
    flann::Matrix<int> indices_flann(thrust::raw_pointer_cast(indices.data()),
                                     query_flann.rows, max_nn);
    flann::Matrix<float> dists_flann(thrust::raw_pointer_cast(distance2.data()),
                                     query_flann.rows, max_nn);
    int k = flann_index_->radiusSearch(query_flann, indices_flann, dists_flann,
                                       float(radius * radius), param);
    return k;
}

template <typename T>
bool KDTreeFlann::SetRawData(const utility::device_vector<T> &data) {
    dimension_ = T::SizeAtCompileTime;
    dataset_size_ = data.size();
    if (dimension_ == 0 || dataset_size_ == 0) {
        utility::LogWarning(
                "[KDTreeFlann::SetRawData] Failed due to no data.\n");
        return false;
    }
    data_.resize(dataset_size_);
    convert_float4_functor<T::RowsAtCompileTime> func;
    thrust::transform(data.begin(), data.end(), data_.begin(), func);
    flann_dataset_.reset(new flann::Matrix<float>(
            (float *)thrust::raw_pointer_cast(data_.data()), dataset_size_,
            dimension_, sizeof(float) * 4));
    flann::KDTreeCuda3dIndexParams index_params;
    flann_index_.reset(new flann::KDTreeCuda3dIndex<flann::L2<float>>(
            *flann_dataset_, index_params));
    flann_index_->buildIndex();
    return true;
}

template <typename T>
int KDTreeFlann::Search(const T &query,
                        const KDTreeSearchParam &param,
                        thrust::host_vector<int> &indices,
                        thrust::host_vector<float> &distance2) const {
    utility::device_vector<T> query_dv(1, query);
    utility::device_vector<int> indices_dv;
    utility::device_vector<float> distance2_dv;
    auto result = Search<T>(query_dv, param, indices_dv, distance2_dv);
    indices = indices_dv;
    distance2 = distance2_dv;
    return result;
}

template <typename T>
int KDTreeFlann::SearchKNN(const T &query,
                           int knn,
                           thrust::host_vector<int> &indices,
                           thrust::host_vector<float> &distance2) const {
    utility::device_vector<T> query_dv(1, query);
    utility::device_vector<int> indices_dv;
    utility::device_vector<float> distance2_dv;
    auto result = SearchKNN<T>(query_dv, knn, indices_dv, distance2_dv);
    indices = indices_dv;
    distance2 = distance2_dv;
    return result;
}

template <typename T>
int KDTreeFlann::SearchRadius(const T &query,
                              float radius,
                              thrust::host_vector<int> &indices,
                              thrust::host_vector<float> &distance2) const {
    utility::device_vector<T> query_dv(1, query);
    utility::device_vector<int> indices_dv;
    utility::device_vector<float> distance2_dv;
    auto result = SearchRadius<T>(query_dv, radius, indices_dv, distance2_dv);
    indices = indices_dv;
    distance2 = distance2_dv;
    return result;
}

template <typename T>
int KDTreeFlann::SearchHybrid(const T &query,
                              float radius,
                              int max_nn,
                              thrust::host_vector<int> &indices,
                              thrust::host_vector<float> &distance2) const {
    utility::device_vector<T> query_dv(1, query);
    utility::device_vector<int> indices_dv;
    utility::device_vector<float> distance2_dv;
    auto result =
            SearchHybrid<T>(query_dv, radius, max_nn, indices_dv, distance2_dv);
    indices = indices_dv;
    distance2 = distance2_dv;
    return result;
}

template int KDTreeFlann::Search<Eigen::Vector3f>(
        const utility::device_vector<Eigen::Vector3f> &query,
        const KDTreeSearchParam &param,
        utility::device_vector<int> &indices,
        utility::device_vector<float> &distance2) const;
template int KDTreeFlann::SearchKNN<Eigen::Vector3f>(
        const utility::device_vector<Eigen::Vector3f> &query,
        int knn,
        utility::device_vector<int> &indices,
        utility::device_vector<float> &distance2) const;
template int KDTreeFlann::SearchRadius<Eigen::Vector3f>(
        const utility::device_vector<Eigen::Vector3f> &query,
        float radius,
        utility::device_vector<int> &indices,
        utility::device_vector<float> &distance2) const;
template int KDTreeFlann::SearchHybrid<Eigen::Vector3f>(
        const utility::device_vector<Eigen::Vector3f> &query,
        float radius,
        int max_nn,
        utility::device_vector<int> &indices,
        utility::device_vector<float> &distance2) const;
template int KDTreeFlann::Search<Eigen::Vector3f>(
        const Eigen::Vector3f &query,
        const KDTreeSearchParam &param,
        thrust::host_vector<int> &indices,
        thrust::host_vector<float> &distance2) const;
template int KDTreeFlann::SearchKNN<Eigen::Vector3f>(
        const Eigen::Vector3f &query,
        int knn,
        thrust::host_vector<int> &indices,
        thrust::host_vector<float> &distance2) const;
template int KDTreeFlann::SearchRadius<Eigen::Vector3f>(
        const Eigen::Vector3f &query,
        float radius,
        thrust::host_vector<int> &indices,
        thrust::host_vector<float> &distance2) const;
template int KDTreeFlann::SearchHybrid<Eigen::Vector3f>(
        const Eigen::Vector3f &query,
        float radius,
        int max_nn,
        thrust::host_vector<int> &indices,
        thrust::host_vector<float> &distance2) const;
template bool KDTreeFlann::SetRawData<Eigen::Vector3f>(
        const utility::device_vector<Eigen::Vector3f> &data);

template int KDTreeFlann::Search<Eigen::Vector2f>(
        const utility::device_vector<Eigen::Vector2f> &query,
        const KDTreeSearchParam &param,
        utility::device_vector<int> &indices,
        utility::device_vector<float> &distance2) const;
template int KDTreeFlann::SearchKNN<Eigen::Vector2f>(
        const utility::device_vector<Eigen::Vector2f> &query,
        int knn,
        utility::device_vector<int> &indices,
        utility::device_vector<float> &distance2) const;
template int KDTreeFlann::SearchRadius<Eigen::Vector2f>(
        const utility::device_vector<Eigen::Vector2f> &query,
        float radius,
        utility::device_vector<int> &indices,
        utility::device_vector<float> &distance2) const;
template int KDTreeFlann::SearchHybrid<Eigen::Vector2f>(
        const utility::device_vector<Eigen::Vector2f> &query,
        float radius,
        int max_nn,
        utility::device_vector<int> &indices,
        utility::device_vector<float> &distance2) const;
template int KDTreeFlann::Search<Eigen::Vector2f>(
        const Eigen::Vector2f &query,
        const KDTreeSearchParam &param,
        thrust::host_vector<int> &indices,
        thrust::host_vector<float> &distance2) const;
template int KDTreeFlann::SearchKNN<Eigen::Vector2f>(
        const Eigen::Vector2f &query,
        int knn,
        thrust::host_vector<int> &indices,
        thrust::host_vector<float> &distance2) const;
template int KDTreeFlann::SearchRadius<Eigen::Vector2f>(
        const Eigen::Vector2f &query,
        float radius,
        thrust::host_vector<int> &indices,
        thrust::host_vector<float> &distance2) const;
template int KDTreeFlann::SearchHybrid<Eigen::Vector2f>(
        const Eigen::Vector2f &query,
        float radius,
        int max_nn,
        thrust::host_vector<int> &indices,
        thrust::host_vector<float> &distance2) const;
template bool KDTreeFlann::SetRawData<Eigen::Vector2f>(
        const utility::device_vector<Eigen::Vector2f> &data);
