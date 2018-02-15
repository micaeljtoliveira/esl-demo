#!/usr/bin/env bash
source /etc/profile.d/lmod.sh
module use $HOME/modules 
module load gnu/7  fftw3/3.3.6 openmpi/3.0.0 scalapack/2.0.2 esl/openmpi/0.0.1
mkdir build-paranoid
pushd build-paranoid
export FC=gfortran
FFLAGS="-g -frecord-gcc-switches -Wall -O0 -std=f2008 -pedantic -fbacktrace -fcheck=all -finit-integer=snan -finit-real=snan -finit-logical=true -finit-character=42 -ffpe-trap=invalid,zero,overflow -fdump-core" cmake ../ 
make -j VERBOSE=1
