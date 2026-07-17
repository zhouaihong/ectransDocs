## 1.fiat
```bash
(base) acict_hpjia_1@ln301:~/HDD_POOL/ectrans-dev/Gitclone/fiat$ cmake -S "$EC_HOME/Gitclone/fiat" -B "$EC_HOME/build/fiat" -DCMAKE_INSTALL_PREFIX="$EC_HOME/install/fiat" -DCMAKE_PREFIX_PATH="$EC_HOME/install/ecbuild" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=nvc -DCMAKE_CXX_COMPILER=nvc++ -DCMAKE_Fortran_COMPILER=nvfortran -DENABLE_DUMMY_MPI_HEADER=OFF
(base) acict_hpjia_1@ln301:~/HDD_POOL/ectrans-dev/Gitclone/fiat$ cmake --build "$EC_HOME/build/fiat" -j
(base) acict_hpjia_1@ln301:~/HDD_POOL/ectrans-dev/Gitclone/fiat$ cmake --install "$EC_HOME/build/fiat"
ctest --test-dir "$EC_HOME/build/fiat" --output-on-failure
```