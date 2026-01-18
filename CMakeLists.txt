cmake_minimum_required(VERSION 3.10)
project(WebRTCStreamer VERSION 1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -O3 -march=native")

# Find GStreamer
find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED 
    gstreamer-1.0>=1.18
    gstreamer-sdp-1.0
    gstreamer-webrtc-1.0
    gstreamer-video-1.0
)

# Find other dependencies
pkg_check_modules(JSON REQUIRED jsoncpp)
find_package(Boost REQUIRED COMPONENTS system thread)
find_package(OpenSSL REQUIRED)

include_directories(
    ${CMAKE_SOURCE_DIR}/include
    ${GST_INCLUDE_DIRS}
    ${JSON_INCLUDE_DIRS}
    ${Boost_INCLUDE_DIRS}
    ${OPENSSL_INCLUDE_DIR}
)

link_directories(
    ${GST_LIBRARY_DIRS}
)

# Source files
set(SOURCES
    src/main.cpp
    src/shared_media_pipeline.cpp
    src/signaling_client.cpp
)

# Create executable
add_executable(webrtc_streamer ${SOURCES})

target_link_libraries(webrtc_streamer
    ${GST_LIBRARIES}
    ${JSON_LIBRARIES}
    ${Boost_LIBRARIES}
    ${OPENSSL_LIBRARIES}
    pthread
)

# Install target
install(TARGETS webrtc_streamer DESTINATION bin)
