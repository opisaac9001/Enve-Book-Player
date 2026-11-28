cmake_minimum_required(VERSION 3.22.1)
project(enve_settings_pairing LANGUAGES C)

add_library(enve_settings_pairing SHARED
    enve_pairing.c
    pairing_jni.c
    mbedtls/library/bignum.c
    mbedtls/library/bignum_core.c
    mbedtls/library/bignum_mod.c
    mbedtls/library/bignum_mod_raw.c
    mbedtls/library/constant_time.c
    mbedtls/library/ecjpake.c
    mbedtls/library/ecp.c
    mbedtls/library/ecp_curves.c
    mbedtls/library/ecp_curves_new.c
    mbedtls/library/md.c
    mbedtls/library/platform_util.c
    mbedtls/library/sha256.c
)
target_include_directories(enve_settings_pairing PRIVATE include mbedtls/include mbedtls)
target_compile_definitions(enve_settings_pairing PRIVATE MBEDTLS_CONFIG_FILE="pairing_config.h")
target_compile_options(enve_settings_pairing PRIVATE -fvisibility=hidden)
target_link_options(enve_settings_pairing PRIVATE -Wl,-z,max-page-size=16384)
