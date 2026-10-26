// sherpa-onnx C API shim.
//
// The C API is distributed as static libraries (`app/Vendor/sherpa/lib`) plus
// the public header `sherpa-onnx/c-api/c-api.h`. This translation unit only
// exists so SwiftPM has a compilable C source for the target: it also proves
// that the vendored header is self-contained in C mode.
//
// sherpa-onnx is Copyright (c) 2023 Xiaomi Corporation and licensed under
// Apache-2.0. See ThirdPartyNotices.txt at the repository root.

#include "sherpa-onnx/c-api/c-api.h"
