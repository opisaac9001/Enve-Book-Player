#!/bin/sh
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH}"
git submodule update --init --recursive
