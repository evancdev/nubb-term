// Generates code for every target that this compiler can support.
#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "simd/index_of.cpp"  // this file
#include <hwy/foreach_target.h>                 // must come before highway.h
#include <hwy/highway.h>

#include <simd/index_of.h>

HWY_BEFORE_NAMESPACE();
namespace nubb {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

size_t IndexOf(const uint8_t needle,
               const uint8_t* HWY_RESTRICT input,
               size_t count) {
  const hn::ScalableTag<uint8_t> d;
  return IndexOfImpl(d, needle, input, count);
}

}  // namespace HWY_NAMESPACE
}  // namespace nubb
HWY_AFTER_NAMESPACE();

// HWY_ONCE is true for only one of the target passes
#if HWY_ONCE

namespace nubb {

// This macro declares a static array used for dynamic dispatch.
HWY_EXPORT(IndexOf);

size_t IndexOf(const uint8_t needle,
               const uint8_t* HWY_RESTRICT input,
               size_t count) {
  return HWY_DYNAMIC_DISPATCH(IndexOf)(needle, input, count);
}

}  // namespace nubb

extern "C" {

size_t nubb_simd_index_of(const uint8_t needle,
                             const uint8_t* HWY_RESTRICT input,
                             size_t count) {
  return nubb::IndexOf(needle, input, count);
}
}

#endif  // HWY_ONCE
