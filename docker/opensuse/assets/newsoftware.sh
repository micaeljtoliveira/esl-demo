#!/usr/bin/env bash
set -x
rm -rf $HOME/esl
rm -rf $HOME/modules
source /etc/profile.d/lmod.sh

module load gnu/7 openmpi/3.0.0 scalapack/2.0.2
export LIBRARY_PATH=$LD_LIBRARY_PATH:$LIBRARY_PATH
git clone https://gitlab.e-cam2020.eu/esl/esl-bundle.git
pushd esl-bundle 
mkdir -p /home/drFaustroll/esl-bundle/install/include
echo "prefix='/home/drFaustroll/esl/openmpi/0.1.0'" >> rcfiles/opensuse-gcc-openmpi.rc
./jhbuild.py -f rcfiles/opensuse-gcc-openmpi.rc build esl-bundle
popd

mkdir -p $HOME/modules/esl/openmpi
mv modules-esl-openmpi $HOME/modules/esl/openmpi/0.1.0
rm -rf esl-bundle
rm -rf esl/openmpi/0.1.0/_jhbuild

