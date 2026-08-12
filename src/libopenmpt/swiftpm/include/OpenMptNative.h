#pragma once

// Swift Package Manager requires a public include directory for C-family
// targets. Dart calls libopenmpt's exported C symbols directly through FFI.
#include "../../libopenmpt/libopenmpt.h"
