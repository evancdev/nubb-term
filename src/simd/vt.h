#if defined(NUBB_SIMD_VT_H_) == defined(HWY_TARGET_TOGGLE)
#ifdef NUBB_SIMD_VT_H_
#undef NUBB_SIMD_VT_H_
#else
#define NUBB_SIMD_VT_H_
#endif

#include <hwy/highway.h>

HWY_BEFORE_NAMESPACE();
namespace nubb {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

}  // namespace HWY_NAMESPACE
}  // namespace nubb
HWY_AFTER_NAMESPACE();

#if HWY_ONCE

namespace nubb {

typedef void (*PrintFunc)(const char32_t* chars, size_t count);

}  // namespace nubb

#endif  // HWY_ONCE

#endif  // NUBB_SIMD_VT_H_
