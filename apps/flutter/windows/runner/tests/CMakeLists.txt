cmake_minimum_required(VERSION 3.14)
project(pocox_console_tests LANGUAGES CXX)

# Exercise the release runner's real console policy without loading Flutter or
# touching a user's app data. Run this standalone project with --config Release.
add_executable(console_fixture WIN32 console_fixture.cpp ../console.cpp)
target_compile_features(console_fixture PRIVATE cxx_std_17)
target_compile_options(console_fixture PRIVATE /W4 /WX /utf-8)
target_link_libraries(console_fixture PRIVATE shell32)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
enable_testing()
add_test(NAME console_lifetime
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_console.py
          $<TARGET_FILE:console_fixture>)
set_tests_properties(console_lifetime PROPERTIES TIMEOUT 30)
