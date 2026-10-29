# CMake 3.31 added the iOS + MacOSX SDK mapping to the Mac Catalyst target triple.
if(CMAKE_VERSION VERSION_LESS 3.31)
  message(FATAL_ERROR "Mac Catalyst requires CMake 3.31 or newer. Update with: brew upgrade cmake")
endif()
